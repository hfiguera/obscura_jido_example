// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/obscura_jido_example"
import topbar from "../vendor/topbar"

const SecretInput = {
  mounted() {
    this.input = this.el.querySelector("[data-secret-input]")
    this.toggle = this.el.querySelector("[data-secret-toggle]")
    this.handleToggle = () => {
      const reveal = this.input.type === "password"
      this.input.type = reveal ? "text" : "password"
      this.toggle.setAttribute("aria-pressed", String(reveal))
      this.toggle.setAttribute("aria-label", reveal ? "Hide OpenAI API key" : "Show OpenAI API key")
      this.toggle.setAttribute("title", reveal ? "Hide OpenAI API key" : "Show OpenAI API key")
    }

    this.toggle.addEventListener("click", this.handleToggle)
  },

  destroyed() {
    this.toggle?.removeEventListener("click", this.handleToggle)
  },
}

const AutoDismissFlash = {
  mounted() {
    const delay = Number.parseInt(this.el.dataset.dismissAfter, 10)

    if (Number.isFinite(delay) && delay > 0) {
      this.timer = window.setTimeout(() => this.el.click(), delay)
    }
  },

  destroyed() {
    if (this.timer) window.clearTimeout(this.timer)
  },
}

const ElapsedTime = {
  mounted() {
    const startedAt = Number.parseInt(this.el.dataset.startedAt, 10)

    if (!Number.isFinite(startedAt)) return

    const render = () => {
      const elapsedSeconds = Math.max(Date.now() - startedAt, 0) / 1000
      this.el.textContent = elapsedSeconds < 60
        ? `${elapsedSeconds.toFixed(1)} s`
        : `${Math.floor(elapsedSeconds / 60)}m ${Math.floor(elapsedSeconds % 60)}s`
    }

    render()
    this.timer = window.setInterval(render, 100)
  },

  destroyed() {
    if (this.timer) window.clearInterval(this.timer)
  },
}

const ConversationScroll = {
  mounted() {
    this.stickToBottom = true
    this.handleScroll = () => {
      this.stickToBottom = this.remainingScroll() < 80
    }

    this.el.addEventListener("scroll", this.handleScroll, {passive: true})
    this.scrollToBottom()
  },

  beforeUpdate() {
    this.wasStickingToBottom = this.stickToBottom
  },

  updated() {
    if (this.wasStickingToBottom) this.scrollToBottom()
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll)
  },

  remainingScroll() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
    this.stickToBottom = true
  },
}

const ComposerInput = {
  mounted() {
    this.handleKeydown = event => {
      if (event.key !== "Enter" || event.isComposing || event.keyCode === 229 || event.repeat) return
      if (event.shiftKey && !event.metaKey && !event.ctrlKey) return

      event.preventDefault()

      if (this.el.disabled || this.el.value.trim() === "") return
      this.el.form?.requestSubmit()
    }

    this.el.addEventListener("keydown", this.handleKeydown)
    this.focusOnDesktop()
  },

  beforeUpdate() {
    this.wasDisabled = this.el.disabled
  },

  updated() {
    if (this.wasDisabled && !this.el.disabled) this.focusOnDesktop()
  },

  destroyed() {
    if (this.focusTimer) window.clearTimeout(this.focusTimer)
    this.el.removeEventListener("keydown", this.handleKeydown)
  },

  focusOnDesktop() {
    const mobileDevice = navigator.userAgentData?.mobile === true ||
      /Android|iPhone|iPad|iPod/i.test(navigator.userAgent)

    if (!mobileDevice) {
      if (this.focusTimer) window.clearTimeout(this.focusTimer)

      this.focusTimer = window.setTimeout(() => {
        const end = this.el.value.length

        this.el.focus({preventScroll: true})
        this.el.setSelectionRange(end, end)
        this.el.scrollTop = this.el.scrollHeight
      }, 75)
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    AutoDismissFlash,
    ComposerInput,
    ConversationScroll,
    ElapsedTime,
    SecretInput,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
