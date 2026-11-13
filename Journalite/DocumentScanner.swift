#if os(iOS)
import SwiftUI
import VisionKit

struct DocumentScanner: UIViewControllerRepresentable {
    let finished: (VNDocumentCameraScan) -> Void
    let cancelled: () -> Void
    let failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            if controller.presentingViewController != nil {
                controller.dismiss(animated: true) { self.parent.finished(scan) }
            } else {
                parent.finished(scan)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            if controller.presentingViewController != nil {
                controller.dismiss(animated: true) { self.parent.cancelled() }
            } else {
                parent.cancelled()
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            if controller.presentingViewController != nil {
                controller.dismiss(animated: true) { self.parent.failed() }
            } else {
                parent.failed()
            }
        }
    }
}
#endif
