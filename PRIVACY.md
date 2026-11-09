# Privacy Notes

The V0.1 compatibility test is intentionally data-minimal.

- It does not ask for sign-in.
- It does not connect to OpenList.
- It does not upload browser diagnostics.
- It stores only the demonstration page number in this browser's localStorage.
- It makes one same-origin GET request to /health.json to test HTTPS and XMLHttpRequest.

Do not add real book metadata, book files, account details or service tokens to this public repository.
