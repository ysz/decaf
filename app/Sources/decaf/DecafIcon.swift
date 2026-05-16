import AppKit

/// Loads the hugeicons:coffee-02 SVG (bundled in Contents/Resources/ of the
/// .app) and returns it as an NSImage with template rendering, so macOS tints
/// the silhouette to match the menubar appearance.
///
/// "on"  = original SVG (cup + handle + 3 steam wisps)
/// "off" = same cup + handle, no steam, with a diagonal slash through it.
///
/// We use Bundle.main (which resolves to Contents/Resources/) rather than the
/// SPM-generated Bundle.module. SPM's accessor expects its resource bundle at
/// the .app root, but codesign rejects content at the bundle root — so we
/// bypass it and load the SVGs as plain Contents/Resources/ files.
enum DecafIcon {
    static func image(active: Bool) -> NSImage {
        let name = active ? "coffee-on" : "coffee-off"
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "cup.and.saucer.fill",
                           accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
