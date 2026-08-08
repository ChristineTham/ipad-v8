import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Import/export of the working disk image.
///
/// SwiftUI's `fileExporter` wants a `FileDocument`, which means reading the
/// whole image into memory — 174 MB of it. These panels hand the file system
/// two paths and let it do the copy instead.
enum DiskTransfer {

    static func export(_ url: URL, suggestedName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        #else
        // asCopy: true — the picker copies out of our container rather than
        // handing the sandbox a live reference to the disk V8 is running on.
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        present(picker)
        #endif
    }

    static func importDisk(_ completion: @escaping (URL) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let src = panel.url else { return }
            completion(src)
        }
        #else
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        let delegate = ImportDelegate(completion: completion)
        picker.delegate = delegate
        importDelegate = delegate          // the picker holds its delegate weakly
        present(picker)
        #endif
    }

    #if !os(macOS)
    private static var importDelegate: ImportDelegate?

    private final class ImportDelegate: NSObject, UIDocumentPickerDelegate {
        let completion: (URL) -> Void
        init(completion: @escaping (URL) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { completion(url) }
            DiskTransfer.importDelegate = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DiskTransfer.importDelegate = nil
        }
    }

    private static func present(_ vc: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }
    #endif
}
