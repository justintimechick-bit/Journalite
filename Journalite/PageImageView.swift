import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#endif

struct LocalJPEGView: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: url) {
            image = nil
            image = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
        }
    }
}

struct PageImageView: View {
    let model: JournalAppModel
    let pageID: UUID
    @State private var imageURL: URL?
    @State private var shareURL: URL?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL {
                #if os(iOS)
                ZoomablePage(url: imageURL)
                    .frame(height: 420)
                    .accessibilityLabel("Journal page photo. Pinch to zoom.")
                #else
                LocalJPEGView(url: imageURL).frame(minHeight: 300)
                #endif
                Text("Pinch to zoom. Use the page selector or Previous and Next to turn pages.")
                    .font(.caption).foregroundStyle(.secondary)
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share Copy Without Location", systemImage: "square.and.arrow.up") }
                }
            } else if failed {
                Text("The image could not be opened. Its original record has not been changed.")
                Button("Retry Image") { attempt += 1 }
            } else { ProgressView("Loading page image…") }
        }
        .task(id: "\(pageID)-\(attempt)") {
            imageURL = nil
            shareURL = nil
            failed = false
            do {
                guard let repository = model.repository else { throw PersistenceError.notLoaded }
                let display = try await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .display)
                guard !Task.isCancelled else { return }
                imageURL = display
                shareURL = try await JournalImageCache.shared.image(pageID: pageID, repository: repository, kind: .share)
            } catch { failed = true }
        }
    }
}

#if os(iOS)
struct ZoomablePage: UIViewRepresentable {
    let url: URL
    var background: UIColor = .secondarySystemBackground

    func makeUIView(context: Context) -> PageScrollView { PageScrollView() }
    func updateUIView(_ view: PageScrollView, context: Context) {
        view.backgroundColor = background
        view.load(url)
    }
}

/// The viewer decodes one bounded display derivative, never the source or all pages.
final class PageScrollView: UIScrollView, UIScrollViewDelegate {
    private let pageImage = UIImageView()
    private var loadedURL: URL?
    private var laidOutSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        pageImage.contentMode = .scaleAspectFit
        addSubview(pageImage)
        backgroundColor = .secondarySystemBackground
        accessibilityLabel = "Journal page photo"
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    /// Double-tap zooms in around the tapped point, or back out when already zoomed.
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(maximumZoomScale, 3)
        let point = recognizer.location(in: pageImage)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    required init?(coder: NSCoder) { return nil }

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        setZoomScale(1, animated: false)
        pageImage.image = UIImage(contentsOfFile: url.path)
        pageImage.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            setZoomScale(1, animated: false)
            pageImage.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageImage }
}
#endif
