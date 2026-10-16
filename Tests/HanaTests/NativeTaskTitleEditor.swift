import AppKit

@MainActor
func nativeTaskTitleEditor(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let editor = view as? NSTextView, editor.identifier?.rawValue == "task-title-editor" { return editor }
    return view.subviews.lazy.compactMap { nativeTaskTitleEditor(in: $0) }.first
}
