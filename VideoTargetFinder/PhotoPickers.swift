import SwiftUI
import PhotosUI
import UIKit

private final class ReferenceImageLoadAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var indexedImages: [(Int, UIImage)] = []
    private var firstError: Error?

    func store(index: Int, image: UIImage) {
        lock.lock()
        indexedImages.append((index, image))
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    func result() -> (images: [UIImage], error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (indexedImages.sorted { $0.0 < $1.0 }.map { $0.1 }, firstError)
    }
}

struct VideoPhotoPicker: UIViewControllerRepresentable {
    let onPick: (PHPickerResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (PHPickerResult) -> Void

        init(onPick: @escaping (PHPickerResult) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                picker.dismiss(animated: true)
                return
            }

            let handler = onPick
            picker.dismiss(animated: true) {
                handler(result)
            }
        }
    }
}

struct ReferenceImagesPicker: UIViewControllerRepresentable {
    let maxSelection: Int
    let onPick: ([UIImage]) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onError: onError)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = maxSelection

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: ([UIImage]) -> Void
        private let onError: (Error) -> Void

        init(onPick: @escaping ([UIImage]) -> Void, onError: @escaping (Error) -> Void) {
            self.onPick = onPick
            self.onError = onError
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            let accumulator = ReferenceImageLoadAccumulator()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else {
                    accumulator.store(error: PickerError.unsupportedImage)
                    continue
                }

                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    defer { group.leave() }
                    if let error {
                        accumulator.store(error: error)
                    } else if let image = object as? UIImage {
                        accumulator.store(index: index, image: image)
                    } else {
                        accumulator.store(error: PickerError.unsupportedImage)
                    }
                }
            }

            group.notify(queue: .main) {
                let result = accumulator.result()
                if !result.images.isEmpty {
                    self.onPick(result.images)
                } else if let error = result.error {
                    self.onError(error)
                } else {
                    self.onError(PickerError.unsupportedImage)
                }
            }
        }
    }

    enum PickerError: LocalizedError {
        case unsupportedImage

        var errorDescription: String? {
            "選択した画像を読み込めませんでした。"
        }
    }
}
