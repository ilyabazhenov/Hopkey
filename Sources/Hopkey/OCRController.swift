import AppKit
import CoreImage
import Vision

/// Распознавание текста с выбранной области экрана. Захват — системным `/usr/sbin/screencapture -i`
/// (нативный крестик-выделение, мультидисплей и отмена по Esc «из коробки»), распознавание — Vision
/// на устройстве. Интерактивный screencapture атрибутируется TCC на Apple-бинарник, а не на Hopkey,
/// поэтому **разрешение Screen Recording не требуется**; Vision тоже работает без TCC и без сети.
final class OCRController {

    /// Итог захвата: распознанный текст, снимок без текста или отмена выделения. Разделены, чтобы
    /// вызывающий молчал на осознанной отмене (Esc) и подавал сигнал только при пустом распознавании.
    enum Result {
        case text(String)
        case empty
        case cancelled
    }

    /// Языки распознавания. Русский появился в Vision revision 3 (macOS 13) — совпадает с минимумом
    /// приложения. Порядок — приоритет при разборе неоднозначностей.
    private let languages = ["ru-RU", "en-US"]

    /// Переиспользуемый контекст Core Image для апскейла (создавать на каждый вызов дорого).
    private let ciContext = CIContext()

    /// Целевой размер большей стороны после апскейла мелких выделений (px) и потолок множителя.
    private let upscaleTarget: CGFloat = 1800
    private let upscaleMaxFactor: CGFloat = 4

    /// Захватывает область экрана и распознаёт текст. Колбэк всегда на главной очереди.
    func capture(completion: @escaping (Result) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hopkey-ocr-\(UUID().uuidString).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", url.path]   // интерактивно, без звука затвора, в файл
        task.terminationHandler = { [weak self] _ in
            // Файл удаляем в любом случае: снимок экрана не должен оставаться на диске.
            defer { try? FileManager.default.removeItem(at: url) }
            guard let self,
                  let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                // Esc/отмена → файла нет: молчим, это осознанное действие пользователя.
                DispatchQueue.main.async { completion(.cancelled) }
                return
            }
            self.recognize(cgImage, completion: completion)
        }

        do {
            try task.run()
        } catch {
            NSLog("Hopkey.ocr: не удалось запустить screencapture: \(error)")
            DispatchQueue.main.async { completion(.cancelled) }
        }
    }

    /// Прогоняет Vision по снимку и склеивает строки в исходном порядке. Тяжёлый проход — вне
    /// главной очереди; результат возвращаем на главную.
    private func recognize(_ cgImage: CGImage, completion: @escaping (Result) -> Void) {
        let request = VNRecognizeTextRequest { request, _ in
            let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(trimmed.isEmpty ? .empty : .text(trimmed)) }
        }
        request.recognitionLevel = .accurate
        // Коррекция выключена намеренно: аудитория снимает код/ID/токены/хеши, а коррекция их
        // «исправляет» (O→0, l→1, ломает PROJ-123 и имена переменных). Для прозы это чуть хуже.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        // Пиннинг самой свежей доступной ревизии модели (детерминированно, не зависит от дефолта ОС).
        if let latest = VNRecognizeTextRequest.supportedRevisions.max() {
            request.revision = latest
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = self?.upscaledIfNeeded(cgImage) ?? cgImage
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                NSLog("Hopkey.ocr: Vision не смог распознать: \(error)")
                DispatchQueue.main.async { completion(.empty) }
            }
        }
    }

    /// Апскейлит мелкие снимки (Lanczos) до `upscaleTarget` по большей стороне, не более чем в
    /// `upscaleMaxFactor` раз. Мелкий шрифт — главная причина промахов OCR: у одиночной строки в
    /// 10–11pt глифы для модели «тонкие», а увеличение перед распознаванием заметно поднимает
    /// точность. Крупные выделения не трогаем (множитель ≈1 → возвращаем как есть).
    private func upscaledIfNeeded(_ cgImage: CGImage) -> CGImage {
        let maxDim = CGFloat(max(cgImage.width, cgImage.height))
        guard maxDim > 0 else { return cgImage }
        let scale = min(max(upscaleTarget / maxDim, 1), upscaleMaxFactor)
        guard scale > 1.05 else { return cgImage }

        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return cgImage }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage,
              let scaled = ciContext.createCGImage(output, from: output.extent) else {
            return cgImage
        }
        return scaled
    }
}
