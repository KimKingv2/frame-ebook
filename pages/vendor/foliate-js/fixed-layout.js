const parseViewport = str => str
    ?.split(/[,;\s]/) // NOTE: technically, only the comma is valid
    ?.filter(x => x)
    ?.map(x => x.split('=').map(x => x.trim()))

const getViewport = (doc, viewport) => {
    // use `viewBox` for SVG
    if (doc.documentElement.localName === 'svg') {
        const [, , width, height] = doc.documentElement
            .getAttribute('viewBox')?.split(/\s/) ?? []
        return { width, height }
    }

    // get `viewport` `meta` element
    const meta = parseViewport(doc.querySelector('meta[name="viewport"]')
        ?.getAttribute('content'))
    if (meta) return Object.fromEntries(meta)

    // fallback to book's viewport
    if (typeof viewport === 'string') return parseViewport(viewport)
    if (viewport?.width && viewport.height) return viewport

    // if no viewport (possibly with image directly in spine), get image size
    const img = doc.querySelector('img')
    if (img) return { width: img.naturalWidth, height: img.naturalHeight }

    // just show *something*, i guess...
    console.warn(new Error('Missing viewport properties'))
    return { width: 1000, height: 2000 }
}

export class FixedLayout extends HTMLElement {
    static observedAttributes = ['zoom', 'flow']
    #root = this.attachShadow({ mode: 'closed' })
    #observer = new ResizeObserver(() => {
        if (this.#flow === 'scrolled') this.#renderScrollPages()
        else this.#render()
    })
    #spreads
    #index = -1
    defaultViewport
    spread
    #portrait = false
    #left
    #right
    #center
    #side
    #zoom
    #flow = 'paginated'
    #pageLayout = 'spread'
    #pageContainer
    #scrollContainer
    #scrollPages = []
    #scrollObserver = null
    #scrollIndex = 0
    #scrollFrame = 0
    constructor() {
        super()

        const sheet = new CSSStyleSheet()
        this.#root.adoptedStyleSheets = [sheet]
        sheet.replaceSync(`:host {
            width: 100%;
            height: 100%;
            display: block;
            overflow: hidden;
        }
        #page-container {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
            overflow: auto;
        }
        #scroll-container {
            position: relative;
            width: 100%;
            height: 100%;
            display: none;
            overflow: auto;
            overscroll-behavior: contain;
            scroll-behavior: smooth;
        }
        .scroll-slot {
            position: relative;
            width: min(100%, 1080px);
            margin: 0 auto;
            overflow: hidden;
            background: rgba(0, 0, 0, .035);
        }`)

        this.#pageContainer = document.createElement('div')
        this.#pageContainer.id = 'page-container'
        this.#scrollContainer = document.createElement('div')
        this.#scrollContainer.id = 'scroll-container'
        this.#root.append(this.#pageContainer, this.#scrollContainer)
        this.#scrollContainer.addEventListener('scroll', () => this.#onScroll(), { passive: true })
        this.#observer.observe(this)
    }
    attributeChangedCallback(name, _, value) {
        switch (name) {
            case 'zoom':
                this.#zoom = value !== 'fit-width' && value !== 'fit-page'
                    ? parseFloat(value) : value
                if (this.#flow === 'scrolled') this.#renderScrollPages()
                else this.#render()
                break
            case 'flow': {
                const currentIndex = this.book ? Math.max(0, this.index) : 0
                this.#flow = value === 'scrolled' ? 'scrolled' : 'paginated'
                if (this.book) {
                    if (this.#flow === 'scrolled') this.#showScrollView(currentIndex)
                    else this.#showPageView(currentIndex)
                }
                break
            }
        }
    }
    async #createFrame({ index, src: srcOption }, parent = this.#pageContainer) {
        const srcOptionIsString = typeof srcOption === 'string'
        const src = srcOptionIsString ? srcOption : srcOption?.src
        const onZoom = srcOptionIsString ? null : srcOption?.onZoom
        const element = document.createElement('div')
        element.setAttribute('dir', 'ltr')
        const iframe = document.createElement('iframe')
        element.append(iframe)
        Object.assign(iframe.style, {
            border: '0',
            display: 'none',
            overflow: 'hidden',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts')
        iframe.setAttribute('scrolling', 'no')
        iframe.setAttribute('part', 'filter')
        parent.append(element)
        if (!src) return { blank: true, element, iframe }
        return new Promise(resolve => {
            iframe.addEventListener('load', () => {
                const doc = iframe.contentDocument
                this.dispatchEvent(new CustomEvent('load', { detail: { doc, index } }))
                const { width, height } = getViewport(doc, this.defaultViewport)
                resolve({
                    element, iframe,
                    width: parseFloat(width),
                    height: parseFloat(height),
                    onZoom,
                })
            }, { once: true })
            iframe.src = src
        })
    }
    #render(side = this.#side) {
        if (this.#flow === 'scrolled') {
            this.#renderScrollPages()
            return
        }
        if (!side) return
        const left = this.#left ?? {}
        const right = this.#center ?? this.#right ?? {}
        const target = side === 'left' ? left : right
        const { width, height } = this.getBoundingClientRect()
        const portrait = this.spread !== 'both' && this.spread !== 'portrait'
            && height > width
        this.#portrait = portrait
        const blankWidth = left.width ?? right.width ?? 0
        const blankHeight = left.height ?? right.height ?? 0

        const scale = typeof this.#zoom === 'number' && !isNaN(this.#zoom)
            ? this.#zoom
            : (this.#zoom === 'fit-width'
                ? (portrait || this.#center
                    ? width / (target.width ?? blankWidth)
                    : width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)))
                : (portrait || this.#center
                    ? Math.min(
                        width / (target.width ?? blankWidth),
                        height / (target.height ?? blankHeight))
                    : Math.min(
                        width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)),
                        height / Math.max(
                            left.height ?? blankHeight,
                            right.height ?? blankHeight)))
            ) || 1

        const transform = frame => {
            let { element, iframe, width, height, blank, onZoom } = frame
            if (!iframe) return
            if (onZoom) onZoom({ doc: frame.iframe.contentDocument, scale })
            const iframeScale = onZoom ? scale : 1
            Object.assign(iframe.style, {
                width: `${width * iframeScale}px`,
                height: `${height * iframeScale}px`,
                transform: onZoom ? 'none' : `scale(${scale})`,
                transformOrigin: 'top left',
                display: blank ? 'none' : 'block',
            })
            Object.assign(element.style, {
                width: `${(width ?? blankWidth) * scale}px`,
                height: `${(height ?? blankHeight) * scale}px`,
                overflow: 'hidden',
                display: 'block',
                flexShrink: '0',
                marginBlock: 'auto',
                boxShadow: '0 14px 34px rgba(0, 0, 0, .28)',
            })
            if (portrait && frame !== target) {
                element.style.display = 'none'
            }
        }
        if (this.#center) {
            transform(this.#center)
        } else {
            transform(left)
            transform(right)
        }
    }
    async #showSpread({ left, right, center, side }) {
        this.#pageContainer.replaceChildren()
        this.#left = null
        this.#right = null
        this.#center = null
        if (center) {
            this.#center = await this.#createFrame(center)
            this.#side = 'center'
            this.#render()
        } else {
            this.#left = await this.#createFrame(left)
            this.#right = await this.#createFrame(right)
            this.#side = this.#left.blank ? 'right'
                : this.#right.blank ? 'left' : side
            this.#render()
        }
    }
    #goLeft() {
        if (this.#center || this.#left?.blank) return
        if (this.#portrait && this.#left?.element?.style?.display === 'none') {
            this.#side = 'left'
            this.#render()
            this.#reportLocation('page')
            return true
        }
    }
    #goRight() {
        if (this.#center || this.#right?.blank) return
        if (this.#portrait && this.#right?.element?.style?.display === 'none') {
            this.#side = 'right'
            this.#render()
            this.#reportLocation('page')
            return true
        }
    }
    open(book) {
        this.book = book
        this.#buildSpreads()
        this.#pageContainer.style.display = 'flex'
        this.#scrollContainer.style.display = 'none'
    }
    #buildSpreads() {
        const { rendition } = this.book
        this.spread = rendition?.spread
        this.defaultViewport = rendition?.viewport

        const rtl = this.book.dir === 'rtl'
        const ltr = !rtl
        this.rtl = rtl

        if (rendition?.spread === 'none')
            this.#spreads = this.book.sections.map(section => ({ center: section }))
        else this.#spreads = this.book.sections.reduce((arr, section, i) => {
            const last = arr[arr.length - 1]
            const { pageSpread } = section
            const newSpread = () => {
                const spread = {}
                arr.push(spread)
                return spread
            }
            if (pageSpread === 'center') {
                const spread = last.left || last.right ? newSpread() : last
                spread.center = section
            }
            else if (pageSpread === 'left') {
                const spread = last.center || last.left || ltr && i ? newSpread() : last
                spread.left = section
            }
            else if (pageSpread === 'right') {
                const spread = last.center || last.right || rtl && i ? newSpread() : last
                spread.right = section
            }
            else if (ltr) {
                if (last.center || last.right) newSpread().left = section
                else if (last.left || !i) last.right = section
                else last.left = section
            }
            else {
                if (last.center || last.left) newSpread().right = section
                else if (last.right || !i) last.left = section
                else last.right = section
            }
            return arr
        }, [{}])
    }
    get index() {
        if (this.#flow === 'scrolled') return this.#scrollIndex
        const spread = this.#spreads[this.#index]
        if (!spread) return -1
        const section = spread.center ?? (this.#side === 'left'
            ? spread.left ?? spread.right : spread.right ?? spread.left)
        return section ? this.book.sections.indexOf(section) : -1
    }
    #reportLocation(reason, index = this.index, fraction = 0) {
        const size = this.book?.sections?.[index]?.size ?? 1
        this.dispatchEvent(new CustomEvent('relocate', { detail:
            { reason, range: null, index, fraction, size } }))
    }
    getSpreadOf(section) {
        const spreads = this.#spreads
        for (let index = 0; index < spreads.length; index++) {
            const { left, right, center } = spreads[index]
            if (left === section) return { index, side: 'left' }
            if (right === section) return { index, side: 'right' }
            if (center === section) return { index, side: 'center' }
        }
    }
    async goToSpread(index, side, reason) {
        if (index < 0 || index > this.#spreads.length - 1) return
        if (index === this.#index) {
            this.#render(side)
            return
        }
        this.#index = index
        const spread = this.#spreads[index]
        if (spread.center) {
            const index = this.book.sections.indexOf(spread.center)
            const src = await spread.center?.load?.()
            await this.#showSpread({ center: { index, src } })
        } else {
            const indexL = this.book.sections.indexOf(spread.left)
            const indexR = this.book.sections.indexOf(spread.right)
            const srcL = await spread.left?.load?.()
            const srcR = await spread.right?.load?.()
            const left = { index: indexL, src: srcL }
            const right = { index: indexR, src: srcR }
            await this.#showSpread({ left, right, side })
        }
        this.#reportLocation(reason)
    }
    async select(target) {
        await this.goTo(target)
        // TODO
    }
    async goTo(target) {
        const { book } = this
        const resolved = await target
        const section = book.sections[resolved?.index]
        if (!section) return
        if (this.#flow === 'scrolled') return this.#scrollToIndex(resolved.index)
        const { index, side } = this.getSpreadOf(section)
        await this.goToSpread(index, side)
    }
    async next() {
        if (this.#flow === 'scrolled') return this.#scrollToIndex(this.#scrollIndex + 1)
        const s = this.rtl ? this.#goLeft() : this.#goRight()
        if (!s) return this.goToSpread(this.#index + 1, this.rtl ? 'right' : 'left', 'page')
    }
    async prev() {
        if (this.#flow === 'scrolled') return this.#scrollToIndex(this.#scrollIndex - 1)
        const s = this.rtl ? this.#goRight() : this.#goLeft()
        if (!s) return this.goToSpread(this.#index - 1, this.rtl ? 'left' : 'right', 'page')
    }
    setFlow(mode) {
        if (mode === 'scrolled') this.setAttribute('flow', 'scrolled')
        else this.removeAttribute('flow')
    }
    setPageLayout(layout) {
        const next = layout === '1' || layout === 'single' ? 'single' : 'spread'
        const currentIndex = this.book ? Math.max(0, this.index) : 0
        const desiredSpread = next === 'single' ? 'none' : 'auto'
        if (!this.book) {
            this.#pageLayout = next
            return
        }
        if (next === this.#pageLayout && this.book.rendition?.spread === desiredSpread) return
        this.#pageLayout = next
        this.book.rendition = { ...(this.book.rendition || {}), spread: desiredSpread }
        this.#buildSpreads()
        if (this.#flow === 'scrolled') {
            this.#scrollIndex = currentIndex
            return this.#scrollToIndex(currentIndex, false)
        }
        this.#index = -1
        const section = this.book.sections[currentIndex]
        const target = this.getSpreadOf(section)
        if (target) return this.goToSpread(target.index, target.side, 'page')
    }
    #showScrollView(currentIndex) {
        this.#disposeScrollView()
        this.#pageContainer.style.display = 'none'
        this.#scrollContainer.style.display = 'block'
        this.#scrollPages = (this.book.sections || []).map((section, index) => {
            const slot = document.createElement('div')
            slot.className = 'scroll-slot'
            slot.dataset.index = String(index)
            slot.style.aspectRatio = '0.72'
            slot.style.width = 'min(100%, 1080px)'
            this.#scrollContainer.append(slot)
            return { index, section, slot, frame: null, loading: false }
        })
        this.#scrollIndex = Math.max(0, Math.min(currentIndex, this.#scrollPages.length - 1))
        if ('IntersectionObserver' in window) {
            this.#scrollObserver = new IntersectionObserver(entries => {
                for (const entry of entries) {
                    if (!entry.isIntersecting) continue
                    const index = Number(entry.target.dataset.index)
                    const page = this.#scrollPages[index]
                    if (page) this.#loadScrollPage(page)
                }
            }, { root: this.#scrollContainer, rootMargin: '150% 0px' })
            for (const page of this.#scrollPages) this.#scrollObserver.observe(page.slot)
        } else {
            for (const page of this.#scrollPages) this.#loadScrollPage(page)
        }
        requestAnimationFrame(() => this.#scrollToIndex(this.#scrollIndex, false))
    }
    #disposeScrollView() {
        this.#scrollObserver?.disconnect()
        this.#scrollObserver = null
        for (const page of this.#scrollPages) {
            if (page.frame) page.section.unload?.()
        }
        this.#scrollPages = []
        this.#scrollContainer.replaceChildren()
    }
    async #loadScrollPage(page) {
        if (page.loading || page.frame) return
        page.loading = true
        try {
            const src = await page.section.load?.()
            const frame = await this.#createFrame({ index: page.index, src }, page.slot)
            page.frame = frame
            this.#renderScrollPage(page)
        } catch (error) {
            page.slot.style.background = 'rgba(170, 70, 70, .16)'
            console.error('Could not load comic page', page.index, error)
        } finally {
            page.loading = false
        }
    }
    #renderScrollPage(page) {
        if (!page?.frame || !this.#scrollContainer.clientWidth) return
        const { frame } = page
        const maxWidth = Math.min(this.#scrollContainer.clientWidth, 1080)
        const scale = maxWidth / (frame.width || maxWidth)
        const width = (frame.width || maxWidth) * scale
        const height = (frame.height || maxWidth * 1.4) * scale
        page.slot.style.width = width + 'px'
        page.slot.style.height = height + 'px'
        page.slot.style.aspectRatio = 'auto'
        Object.assign(frame.element.style, {
            position: 'absolute',
            inset: '0',
            width: width + 'px',
            height: height + 'px',
            display: 'block',
            overflow: 'hidden',
            margin: '0 auto',
            flexShrink: '0',
            boxShadow: '0 9px 26px rgba(0, 0, 0, .24)',
        })
        Object.assign(frame.iframe.style, {
            width: (frame.width || maxWidth) + 'px',
            height: (frame.height || height) + 'px',
            transform: 'scale(' + scale + ')',
            transformOrigin: 'top left',
            display: frame.blank ? 'none' : 'block',
        })
    }
    #renderScrollPages() {
        if (this.#flow !== 'scrolled') return
        for (const page of this.#scrollPages) this.#renderScrollPage(page)
    }
    #scrollToIndex(index, smooth = true) {
        const targetIndex = Math.max(0, Math.min(index, this.#scrollPages.length - 1))
        const page = this.#scrollPages[targetIndex]
        if (!page) return
        this.#scrollIndex = targetIndex
        this.#loadScrollPage(page)
        this.#scrollContainer.scrollTo({
            top: page.slot.offsetTop,
            behavior: smooth ? 'smooth' : 'auto',
        })
        this.#reportLocation('page', targetIndex, 0)
    }
    #onScroll() {
        if (this.#flow !== 'scrolled' || this.#scrollFrame) return
        this.#scrollFrame = requestAnimationFrame(() => {
            this.#scrollFrame = 0
            const pages = this.#scrollPages
            if (!pages.length) return
            const marker = this.#scrollContainer.scrollTop + this.#scrollContainer.clientHeight * .45
            let current = pages[0]
            let distance = Infinity
            for (const page of pages) {
                const middle = page.slot.offsetTop + page.slot.offsetHeight / 2
                const nextDistance = Math.abs(middle - marker)
                if (nextDistance < distance) {
                    current = page
                    distance = nextDistance
                }
            }
            const maxScroll = Math.max(0, current.slot.offsetHeight - this.#scrollContainer.clientHeight)
            const fraction = maxScroll
                ? Math.max(0, Math.min(1, (this.#scrollContainer.scrollTop - current.slot.offsetTop) / maxScroll))
                : 0
            if (current.index !== this.#scrollIndex) {
                this.#scrollIndex = current.index
                this.#reportLocation('scroll', current.index, fraction)
            } else {
                this.#reportLocation('scroll', current.index, fraction)
            }
        })
    }
    #showPageView(currentIndex) {
        this.#disposeScrollView()
        this.#scrollContainer.style.display = 'none'
        this.#pageContainer.style.display = 'flex'
        this.#index = -1
        const section = this.book.sections[currentIndex]
        const target = this.getSpreadOf(section)
        if (target) this.goToSpread(target.index, target.side, 'page')
    }
    getContents() {
        if (this.#flow === 'scrolled') {
            return this.#scrollPages.filter(page => page.frame).map(page => ({
                doc: page.frame.iframe.contentDocument,
                index: page.index,
            }))
        }
        return Array.from(this.#pageContainer.querySelectorAll('iframe'), (frame, index) => ({
            doc: frame.contentDocument,
            index,
        }))
    }
    destroy() {
        this.#observer.unobserve(this)
        this.#disposeScrollView()
        this.book?.destroy?.()
        if (this.#scrollFrame) cancelAnimationFrame(this.#scrollFrame)
    }
}

customElements.define('foliate-fxl', FixedLayout)
