use futures_util::StreamExt;
use percent_encoding::percent_decode_str;
use reqwest::{header, redirect::Policy, Client, Method, StatusCode};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    net::IpAddr,
    path::PathBuf,
    sync::Mutex,
    time::Duration,
};
use tauri::{AppHandle, Manager, State};
use tokio::io::AsyncWriteExt;
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WebDavProfile {
    id: String,
    name: String,
    base_url: String,
    username: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct WebDavEntry {
    name: String,
    path: String,
    is_dir: bool,
    size: u64,
    modified: String,
    content_type: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DownloadedFile {
    path: String,
    size: u64,
    redirected: bool,
}

#[derive(Default)]
struct AppState {
    // WebDAV passwords exist only for the lifetime of this app process.
    passwords: Mutex<HashMap<String, String>>,
}

fn app_config_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_config_dir()
        .map_err(|e| format!("無法取得本機設定目錄：{e}"))?;
    fs::create_dir_all(&dir).map_err(|e| format!("無法建立本機設定目錄：{e}"))?;
    Ok(dir)
}

fn app_cache_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_cache_dir()
        .map_err(|e| format!("無法取得本機快取目錄：{e}"))?
        .join("frame-reader-downloads");
    fs::create_dir_all(&dir).map_err(|e| format!("無法建立暫存目錄：{e}"))?;
    Ok(dir)
}

fn profiles_file(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app_config_dir(app)?.join("webdav-profiles.json"))
}

fn read_profiles(app: &AppHandle) -> Result<Vec<WebDavProfile>, String> {
    let path = profiles_file(app)?;
    if !path.exists() { return Ok(Vec::new()); }
    let bytes = fs::read(path).map_err(|e| format!("讀取 WebDAV 設定失敗：{e}"))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("解析 WebDAV 設定失敗：{e}"))
}

fn write_profiles(app: &AppHandle, profiles: &[WebDavProfile]) -> Result<(), String> {
    let path = profiles_file(app)?;
    let bytes = serde_json::to_vec_pretty(profiles)
        .map_err(|e| format!("序列化 WebDAV 設定失敗：{e}"))?;
    fs::write(path, bytes).map_err(|e| format!("寫入 WebDAV 設定失敗：{e}"))
}

fn get_profile_and_password(
    app: &AppHandle,
    state: &AppState,
    profile_id: &str,
) -> Result<(WebDavProfile, String), String> {
    let profiles = read_profiles(app)?;
    let profile = profiles.into_iter().find(|item| item.id == profile_id)
        .ok_or_else(|| "找不到這個 WebDAV 來源設定。".to_string())?;
    let passwords = state.passwords.lock()
        .map_err(|_| "WebDAV 記憶體密碼鎖定失敗。".to_string())?;
    let password = passwords.get(profile_id).cloned()
        .ok_or_else(|| "這個 WebDAV 來源尚未解鎖。請重新輸入密碼；密碼只保留在 FRAME Ebook 執行期間，完全退出 App 後就會清除。".to_string())?;
    Ok((profile, password))
}

fn is_local_host(host: &str) -> bool {
    let clean = host.trim_start_matches('[').trim_end_matches(']');
    if clean.eq_ignore_ascii_case("localhost") || clean.ends_with(".local") { return true; }
    if let Ok(ip) = clean.parse::<IpAddr>() {
        return match ip {
            IpAddr::V4(value) =>
                value.is_private() || value.is_loopback() || value.is_link_local(),
            IpAddr::V6(value) =>
                value.is_loopback() || value.is_unique_local() || value.is_unicast_link_local(),
        };
    }
    false
}

fn normalize_base_url(value: &str) -> Result<String, String> {
    let input = value.trim();
    let mut url = Url::parse(input).map_err(|_| "WebDAV 地址格式不正確。".to_string())?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err("WebDAV 地址必須使用 HTTP 或 HTTPS。".into());
    }
    if !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some()
    {
        return Err("WebDAV 地址不可包含帳密、查詢參數或片段。".into());
    }
    let host = url.host_str().ok_or_else(|| "WebDAV 地址缺少主機名稱。".to_string())?;
    if url.scheme() == "http" && !is_local_host(host) {
        return Err("HTTP 僅允許 localhost、.local 或私有區域網路位址；外網請使用 HTTPS。".into());
    }
    if !url.path().ends_with('/') {
        let next = format!("{}/", url.path());
        url.set_path(&next);
    }
    Ok(url.to_string())
}

fn normalize_remote_path(value: &str) -> Result<String, String> {
    let path = value.trim().replace('\\', "/");
    if !path.starts_with('/') || path.contains('\0') {
        return Err("WebDAV 路徑格式不正確。".into());
    }
    for part in path.split('/') {
        if part == "." || part == ".." {
            return Err("WebDAV 路徑不可包含 . 或 ..。".into());
        }
    }
    Ok(path)
}

fn resource_url(profile: &WebDavProfile, path: &str, collection: bool) -> Result<Url, String> {
    let safe_path = normalize_remote_path(path)?;
    let mut url = Url::parse(&profile.base_url)
        .map_err(|e| format!("WebDAV 地址無效：{e}"))?;
    {
        let mut segments = url.path_segments_mut()
            .map_err(|_| "WebDAV 地址無法加入檔案路徑。".to_string())?;
        segments.pop_if_empty();
        for part in safe_path.split('/').filter(|item| !item.is_empty()) {
            segments.push(part);
        }
        if collection { segments.push(""); }
    }
    Ok(url)
}

fn make_client() -> Result<Client, String> {
    Client::builder()
        .redirect(Policy::none())
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(300))
        .user_agent("FRAME-Ebook-macOS/0.1")
        .build()
        .map_err(|e| format!("建立 WebDAV 連線失敗：{e}"))
}

fn node_text<'a>(node: roxmltree::Node<'a, 'a>, name: &str) -> Option<String> {
    node.descendants()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .and_then(|child| child.text())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn decoded_last_segment(value: &str) -> String {
    let segment = value.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    percent_decode_str(segment).decode_utf8_lossy().to_string()
}

fn parse_multistatus(
    xml: &str,
    requested_path: &str,
    target_url: &Url,
) -> Result<Vec<WebDavEntry>, String> {
    let document = roxmltree::Document::parse(xml)
        .map_err(|e| format!("WebDAV PROPFIND 回傳的 XML 無法解析：{e}"))?;
    let mut entries = Vec::new();
    for response in document.descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "response")
    {
        let href = node_text(response, "href").unwrap_or_default();
        if !href.is_empty() {
            if let Ok(resolved) = target_url.join(&href) {
                if resolved.path().trim_end_matches('/')
                    == target_url.path().trim_end_matches('/')
                {
                    continue;
                }
            }
        }
        let is_dir = response.descendants()
            .any(|node| node.is_element() && node.tag_name().name() == "collection");
        let name = node_text(response, "displayname")
            .unwrap_or_else(|| decoded_last_segment(&href));
        if name.is_empty() || name == "." || name == ".."
            || name.contains('/') || name.contains('\\')
        {
            continue;
        }
        let size = node_text(response, "getcontentlength")
            .and_then(|value| value.parse::<u64>().ok()).unwrap_or(0);
        let modified = node_text(response, "getlastmodified").unwrap_or_default();
        let content_type = node_text(response, "getcontenttype").unwrap_or_default();
        let parent = requested_path.trim_end_matches('/');
        let item_path = if parent.is_empty() {
            format!("/{name}")
        } else {
            format!("{parent}/{name}")
        };
        entries.push(WebDavEntry { name, path: item_path, is_dir, size, modified, content_type });
    }
    entries.sort_by(|a, b|
        b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    );
    Ok(entries)
}

#[tauri::command(rename_all = "camelCase")]
fn list_webdav_profiles(app: AppHandle) -> Result<Vec<WebDavProfile>, String> {
    read_profiles(&app)
}

#[tauri::command(rename_all = "camelCase")]
fn webdav_has_password(state: State<'_, AppState>, profile_id: String) -> bool {
    state.passwords.lock()
        .map(|passwords| passwords.contains_key(&profile_id))
        .unwrap_or(false)
}

#[tauri::command(rename_all = "camelCase")]
fn save_webdav_profile(
    app: AppHandle,
    state: State<'_, AppState>,
    name: String,
    base_url: String,
    username: String,
    password: String,
) -> Result<WebDavProfile, String> {
    let clean_name = name.trim();
    let clean_user = username.trim();
    if clean_name.is_empty() || clean_user.is_empty() || password.is_empty() {
        return Err("請完整填寫來源名稱、帳號與密碼。".into());
    }
    let normalized_url = normalize_base_url(&base_url)?;
    let mut profiles = read_profiles(&app)?;
    let existing_index = profiles.iter().position(|item|
        item.base_url == normalized_url && item.username == clean_user
    );
    let profile = WebDavProfile {
        id: existing_index
            .map(|index| profiles[index].id.clone())
            .unwrap_or_else(|| Uuid::new_v4().to_string()),
        name: clean_name.chars().take(48).collect(),
        base_url: normalized_url,
        username: clean_user.chars().take(180).collect(),
    };
    if let Some(index) = existing_index {
        profiles[index] = profile.clone();
    } else {
        profiles.push(profile.clone());
    }
    write_profiles(&app, &profiles)?;
    state.passwords.lock()
        .map_err(|_| "WebDAV 記憶體密碼鎖定失敗。".to_string())?
        .insert(profile.id.clone(), password);
    Ok(profile)
}

#[tauri::command(rename_all = "camelCase")]
fn delete_webdav_profile(
    app: AppHandle,
    state: State<'_, AppState>,
    profile_id: String,
) -> Result<(), String> {
    let mut profiles = read_profiles(&app)?;
    profiles.retain(|item| item.id != profile_id);
    write_profiles(&app, &profiles)?;
    state.passwords.lock()
        .map_err(|_| "WebDAV 記憶體密碼鎖定失敗。".to_string())?
        .remove(&profile_id);
    Ok(())
}

#[tauri::command(rename_all = "camelCase")]
async fn webdav_list_directory(
    app: AppHandle,
    state: State<'_, AppState>,
    profile_id: String,
    path: String,
) -> Result<Vec<WebDavEntry>, String> {
    let (profile, password) = get_profile_and_password(&app, &state, &profile_id)?;
    let target = resource_url(&profile, &path, true)?;
    let body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>"#;
    let method = Method::from_bytes(b"PROPFIND").map_err(|e| e.to_string())?;
    let response = make_client()?.request(method, target.clone())
        .basic_auth(&profile.username, Some(password))
        .header("Depth", "1")
        .header(header::CONTENT_TYPE, "application/xml; charset=utf-8")
        .body(body)
        .send().await.map_err(|e| format!("WebDAV 連線失敗：{e}"))?;
    if response.status() == StatusCode::UNAUTHORIZED {
        return Err("WebDAV 驗證失敗，請檢查帳號與密碼。".into());
    }
    if response.status() != StatusCode::MULTI_STATUS && !response.status().is_success() {
        return Err(format!("WebDAV PROPFIND 失敗（HTTP {}）。", response.status()));
    }
    let xml = response.text().await
        .map_err(|e| format!("讀取 WebDAV 目錄清單失敗：{e}"))?;
    parse_multistatus(&xml, &path, &target)
}

fn validate_redirect(url: &Url) -> Result<(), String> {
    if !url.username().is_empty() || url.password().is_some() {
        return Err("WebDAV 302 目的網址含有帳號資訊，已拒絕。".into());
    }
    let host = url.host_str()
        .ok_or_else(|| "WebDAV 302 目的網址缺少主機名稱。".to_string())?;
    if url.scheme() != "https" && !(url.scheme() == "http" && is_local_host(host)) {
        return Err("WebDAV 302 目的網址必須使用 HTTPS（區域網路可使用 HTTP）。".into());
    }
    Ok(())
}

fn parse_content_range(value: &str) -> Option<(u64, u64, u64)> {
    let value = value.strip_prefix("bytes ")?;
    let (range, total) = value.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    Some((start.parse().ok()?, end.parse().ok()?, total.parse().ok()?))
}

async fn request_webdav_range(
    profile: &WebDavProfile,
    password: &str,
    path: &str,
    start: u64,
    length: u64,
) -> Result<(Vec<u8>, u64, bool), String> {
    if length == 0 || length > 1_048_576 {
        return Err("漫畫 Range 請求長度不正確（單次上限 1 MiB）。".into());
    }
    let end = start.checked_add(length - 1)
        .ok_or_else(|| "漫畫 Range 位移超出允許範圍。".to_string())?;
    let mut current = resource_url(profile, path, false)?;
    let client = make_client()?;
    let mut redirected = false;

    for hop in 0..=6 {
        let mut request = client.get(current.clone())
            .header(header::RANGE, format!("bytes={start}-{end}"));
        if hop == 0 {
            request = request.basic_auth(&profile.username, Some(password));
        }
        let response = request.send().await
            .map_err(|e| format!("WebDAV Range 讀取失敗：{e}"))?;

        if response.status().is_redirection() {
            let location = response.headers().get(header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| "WebDAV Range 302 缺少 Location。".to_string())?;
            let next = current.join(location)
                .map_err(|e| format!("WebDAV Range 302 目的網址無效：{e}"))?;
            validate_redirect(&next)?;
            current = next;
            redirected = true;
            continue;
        }
        if response.status() == StatusCode::UNAUTHORIZED {
            return Err("WebDAV 驗證失敗，請檢查帳號與密碼。".into());
        }
        if response.status() != StatusCode::PARTIAL_CONTENT {
            return Err(format!(
                "這個 WebDAV 來源或 302 目的位置不支援 HTTP Range（收到 HTTP {}，預期 206）。為避免把整部漫畫下載到 SSD，已停止讀取。",
                response.status()
            ));
        }
        let content_range = response.headers().get(header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .and_then(parse_content_range)
            .ok_or_else(|| "WebDAV Range 回應缺少有效的 Content-Range。".to_string())?;
        let (actual_start, actual_end, total_size) = content_range;
        if actual_start != start || actual_end < actual_start || actual_end > end || total_size <= actual_end {
            return Err("WebDAV Range 回應的位移或檔案總長度不正確。".into());
        }
        let bytes = response.bytes().await
            .map_err(|e| format!("讀取漫畫 Range 資料失敗：{e}"))?;
        let expected = (actual_end - actual_start + 1) as usize;
        if bytes.len() != expected {
            return Err(format!("漫畫 Range 資料不完整：預期 {expected} bytes，實際 {} bytes。", bytes.len()));
        }
        return Ok((bytes.to_vec(), total_size, redirected));
    }
    Err("WebDAV Range 302 跳轉次數過多，已停止請求。".into())
}

#[tauri::command(rename_all = "camelCase")]
async fn webdav_get_file_size(
    app: AppHandle,
    state: State<'_, AppState>,
    profile_id: String,
    path: String,
) -> Result<u64, String> {
    let (profile, password) = get_profile_and_password(&app, &state, &profile_id)?;
    let mut current = resource_url(&profile, &path, false)?;
    let client = make_client()?;

    for hop in 0..=6 {
        let mut request = client.request(Method::HEAD, current.clone());
        if hop == 0 {
            request = request.basic_auth(&profile.username, Some(password.clone()));
        }
        let response = request.send().await
            .map_err(|e| format!("WebDAV 檔案資訊讀取失敗：{e}"))?;
        if response.status().is_redirection() {
            let location = response.headers().get(header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| "WebDAV HEAD 302 缺少 Location。".to_string())?;
            let next = current.join(location)
                .map_err(|e| format!("WebDAV HEAD 302 目的網址無效：{e}"))?;
            validate_redirect(&next)?;
            current = next;
            continue;
        }
        if response.status() == StatusCode::UNAUTHORIZED {
            return Err("WebDAV 驗證失敗，請檢查帳號與密碼。".into());
        }
        if response.status() == StatusCode::NOT_FOUND {
            return Err("WebDAV 找不到這個漫畫檔案。".into());
        }
        if response.status().is_success() {
            if let Some(size) = response.content_length().filter(|size| *size > 0) {
                return Ok(size);
            }
        }
        break;
    }

    // Some WebDAV gateways do not implement HEAD. Probe one byte instead.
    let (_, size, _) = request_webdav_range(&profile, &password, &path, 0, 1).await?;
    if size == 0 {
        return Err("WebDAV 回報的漫畫檔案大小為 0。".into());
    }
    Ok(size)
}

#[tauri::command(rename_all = "camelCase")]
async fn webdav_read_range(
    app: AppHandle,
    state: State<'_, AppState>,
    profile_id: String,
    path: String,
    start: u64,
    length: u64,
) -> Result<tauri::ipc::Response, String> {
    let (profile, password) = get_profile_and_password(&app, &state, &profile_id)?;
    let (bytes, _total_size, _redirected) =
        request_webdav_range(&profile, &password, &path, start, length).await?;
    Ok(tauri::ipc::Response::new(bytes))
}

#[tauri::command(rename_all = "camelCase")]
async fn webdav_download_file(
    app: AppHandle,
    state: State<'_, AppState>,
    profile_id: String,
    path: String,
) -> Result<DownloadedFile, String> {
    let (profile, password) = get_profile_and_password(&app, &state, &profile_id)?;
    let mut current = resource_url(&profile, &path, false)?;
    let client = make_client()?;
    let mut redirected = false;
    let mut response = None;
    for hop in 0..=6 {
        let mut request = client.get(current.clone());
        if hop == 0 {
            request = request.basic_auth(&profile.username, Some(password.clone()));
        }
        let result = request.send().await
            .map_err(|e| format!("WebDAV 檔案請求失敗：{e}"))?;
        if result.status().is_redirection() {
            let location = result.headers().get(header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| "WebDAV 回傳 302，但缺少 Location。".to_string())?;
            let next = current.join(location)
                .map_err(|e| format!("WebDAV 302 目的網址無效：{e}"))?;
            validate_redirect(&next)?;
            current = next;
            redirected = true;
            continue;
        }
        if result.status() == StatusCode::UNAUTHORIZED {
            return Err("WebDAV 驗證失敗，請檢查帳號與密碼。".into());
        }
        if !result.status().is_success() {
            return Err(format!("WebDAV 下載失敗（HTTP {}）。", result.status()));
        }
        response = Some(result);
        break;
    }
    let response = response
        .ok_or_else(|| "WebDAV 302 跳轉次數過多，已停止請求。".to_string())?;
    let expected_size = response.content_length().unwrap_or(0);
    let cache_dir = app_cache_dir(&app)?;
    let destination = cache_dir.join(format!("{}.book", Uuid::new_v4()));
    let mut file = tokio::fs::File::create(&destination).await
        .map_err(|e| format!("建立閱讀暫存檔失敗：{e}"))?;
    let mut stream = response.bytes_stream();
    let mut written = 0u64;
    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|e| format!("讀取 WebDAV 檔案資料失敗：{e}"))?;
        file.write_all(&bytes).await
            .map_err(|e| format!("寫入閱讀暫存檔失敗：{e}"))?;
        written += bytes.len() as u64;
    }
    file.flush().await.map_err(|e| format!("完成閱讀暫存檔失敗：{e}"))?;
    drop(file);
    if expected_size > 0 && written != expected_size {
        let _ = tokio::fs::remove_file(&destination).await;
        return Err(format!(
            "書檔下載不完整：預期 {expected_size} bytes，實際 {written} bytes。"
        ));
    }
    Ok(DownloadedFile {
        path: destination.to_string_lossy().to_string(),
        size: written,
        redirected,
    })
}

#[tauri::command(rename_all = "camelCase")]
async fn delete_cached_file(app: AppHandle, path: String) -> Result<(), String> {
    let cache_dir = app_cache_dir(&app)?;
    let candidate = PathBuf::from(path);
    if !candidate.starts_with(&cache_dir) {
        return Err("拒絕刪除暫存目錄以外的檔案。".into());
    }
    match tokio::fs::remove_file(candidate).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("清除閱讀暫存檔失敗：{error}")),
    }
}

pub fn run() {
    tauri::Builder::default()
        .manage(AppState::default())
        .setup(|app| {
            let handle = app.handle();
            let _ = app_config_dir(handle);
            let _ = app_cache_dir(handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_webdav_profiles,
            webdav_has_password,
            save_webdav_profile,
            delete_webdav_profile,
            webdav_list_directory,
            webdav_get_file_size,
            webdav_read_range,
            webdav_download_file,
            delete_cached_file
        ])
        .run(tauri::generate_context!())
        .expect("error while running FRAME Ebook macOS");
}
