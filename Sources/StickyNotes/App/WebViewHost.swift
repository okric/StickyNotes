import AppKit

/// A window that can hold the single shared `WKWebView`.
///
/// Normal note windows and the stack window both implement this, so the shared
/// editor can be moved between them (and snapshot the window it leaves behind)
/// without knowing which kind of host it is in.
protocol WebViewHost: AnyObject {
    var hasWebView: Bool { get set }
    var contentSize: NSSize { get }
    func showSnapshot(_ image: NSImage)
    func showTextPreview()
    func revealWebView()
}
