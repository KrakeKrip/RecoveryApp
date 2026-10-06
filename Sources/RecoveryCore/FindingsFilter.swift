@preconcurrency import Foundation

/// Категория находки быстрого поиска — только подсказка по расширению файла.
/// Она не доказывает содержимое: файл с расширением `.jpg` может быть любым
/// данным. Файлы без расширения и с неизвестным расширением — «Другое».
public enum FindingsCategory: String, CaseIterable, Sendable, Equatable {
    case all = "Все"
    case photo = "Фото"
    case video = "Видео"
    case document = "Документы"
    case other = "Другое"

    /// Зафиксированная таблица расширений (в нижнем регистре, без точки).
    /// Изменение таблицы — изменение поведения фильтра: править вместе с
    /// ARCHITECTURE.md.
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"
    ]
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "mts", "m2ts", "3gp", "webm"
    ]
    public static let documentExtensions: Set<String> = [
        "pdf", "txt", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "odt", "ods", "csv"
    ]

    /// Категория по расширению имени; регистр расширения не важен.
    /// Пустое расширение и неизвестное — «Другое».
    public static func category(forDisplayName displayName: String) -> FindingsCategory {
        let ext = (displayName as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .other }
        if photoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        if documentExtensions.contains(ext) { return .document }
        return .other
    }
}

/// Ошибки валидации размерных порогов фильтра: запрос с ошибкой не
/// применяется, восстановление блокируется до исправления или сброса.
public enum FindingsFilterError: LocalizedError, Equatable {
    case thresholdNotANumber(String)
    case thresholdNegative(String)
    case thresholdOverflow(String)
    case minAboveMax(minimum: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .thresholdNotANumber(let field):
            "Порог «\(field)» — не число. Введите целое значение в МБ или оставьте поле пустым."
        case .thresholdNegative(let field):
            "Порог «\(field)» отрицательный. Введите неотрицательное целое значение в МБ."
        case .thresholdOverflow(let field):
            "Порог «\(field)» слишком велик для целого числа. Введите меньшее значение в МБ."
        case .minAboveMax(let minimum, let maximum):
            "Минимальный размер (\(minimum) МБ) больше максимального (\(maximum) МБ). Исправьте пороги или сбросьте фильтр размера."
        }
    }
}

/// Необязательные размерные пороги в МБ (1 МБ = 1 000 000 байт,
/// десятичные мегабайты — по запросу пользователя), включительные границы.
/// `nil` — ограничение отключено.
public struct FindingsSizeRange: Sendable, Equatable {
    public let minimumMB: Int?
    public let maximumMB: Int?

    /// 1 МБ = 1 000 000 байт.
    public static let mbByteSize: Int64 = 1_000_000
    /// Максимальный безопасный порог в МБ: умножение на размер МБ не
    /// переполняет Int64. Пороги выше — `thresholdOverflow` при разборе,
    /// а напрямую сконструированный недопустимый диапазон даёт `byteRange == nil`.
    public static let maxSafeThresholdMB: Int = Int(Int64.max / Self.mbByteSize)

    public init(minimumMB: Int?, maximumMB: Int?) {
        self.minimumMB = minimumMB
        self.maximumMB = maximumMB
    }

    /// Есть ли хотя бы один активный порог: при активном пороге находки
    /// с неизвестным размером исключаются из выдачи.
    public var isActive: Bool {
        minimumMB != nil || maximumMB != nil
    }

    /// Включительные границы в байтах; `nil` — диапазон непредставим
    /// (порог выше безопасной границы) либо ограничения отключены.
    /// Никакого переполнения: публичный API не применяет непредставимый
    /// диапазон вместо аварийного завершения.
    public var byteRange: (lower: Int64, upper: Int64)? {
        guard isActive, let scaled = Self.scaledBounds(
            minimumMB: minimumMB, maximumMB: maximumMB
        ) else {
            return nil
        }
        return scaled
    }

    /// Активный, но непредставимый диапазон (порог выше безопасной границы,
    /// например при прямом конструировании мимо `parse`). Отличим от
    /// отключённых ограничений и не расширяет выдачу: `matches` исключает
    /// все находки, а не снимает размерное ограничение.
    public var isUnrepresentable: Bool {
        isActive && byteRange == nil
    }

    static func scaledBounds(
        minimumMB: Int?,
        maximumMB: Int?
    ) -> (lower: Int64, upper: Int64)? {
        // Отсутствующая сторона — «не ограничена» (0 / Int64.max);
        // порог выше безопасной границы делает диапазон непредставимым.
        var lower = Int64(0)
        var upper = Int64.max
        if let minimumMB {
            guard minimumMB >= 0, minimumMB <= maxSafeThresholdMB else { return nil }
            lower = Int64(minimumMB) * Self.mbByteSize
        }
        if let maximumMB {
            guard maximumMB >= 0, maximumMB <= maxSafeThresholdMB else { return nil }
            upper = Int64(maximumMB) * Self.mbByteSize
        }
        return (lower, upper)
    }

    /// Валидация строк полей в МБ (1 МБ = 1 000 000 Б): пустая строка —
    /// ограничение отключено; нечисловое, отрицательное, переполнение —
    /// ошибка; минимум больше максимума — ошибка. Возвращается диапазон или
    /// короткая локальная ошибка с именем поля.
    public static func parse(
        minimumText: String,
        maximumText: String
    ) -> Result<FindingsSizeRange, FindingsFilterError> {
        switch parseField(minimumText, field: "минимум") {
        case .failure(let error):
            return .failure(error)
        case .success(let minimum):
            switch parseField(maximumText, field: "максимум") {
            case .failure(let error):
                return .failure(error)
            case .success(let maximum):
                if let min = minimum, let max = maximum, min > max {
                    return .failure(.minAboveMax(minimum: min, maximum: max))
                }
                return .success(FindingsSizeRange(minimumMB: minimum, maximumMB: maximum))
            }
        }
    }

    /// Разбор одного поля порога: пустая строка (или из пробелов) — `nil`;
    /// отрицательное число (включая переполняющее) — `.thresholdNegative`;
    /// целое вне диапазона `Int` — `.thresholdOverflow`; остальное —
    /// `.thresholdNotANumber`.
    private static func parseField(
        _ text: String,
        field: String
    ) -> Result<Int?, FindingsFilterError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .success(nil) }

        let isNegative = trimmed.hasPrefix("-")
        let digits = isNegative ? Substring(trimmed.dropFirst()) : Substring(trimmed)
        let allDigits = !digits.isEmpty && digits.allSatisfy { $0.isNumber }

        guard allDigits else { return .failure(.thresholdNotANumber(field)) }
        if isNegative { return .failure(.thresholdNegative(field)) }
        guard let value = Int(trimmed) else { return .failure(.thresholdOverflow(field)) }
        // Порог выше безопасной границы (умножение на размер МБ переполнит
        // Int64) — overflow, а не отложенный крах при вычислении байтов.
        guard value <= FindingsSizeRange.maxSafeThresholdMB else {
            return .failure(.thresholdOverflow(field))
        }
        return .success(value)
    }
}

/// Запрос фильтра найденных файлов: категория, поиск по имени и размерные
/// пороги объединяются по AND. Пустой запрос (категория «Все», пустое имя,
/// без порогов) не отсеивает ничего.
public struct FindingsFilter: Sendable, Equatable {
    public let category: FindingsCategory
    /// Поиск по имени: нечувствителен к регистру, вхождение в displayName;
    /// пробелы по краям убраны; кириллица поддерживается сравнением с
    /// локализованной нижней границей.
    public let nameQuery: String
    public let sizeRange: FindingsSizeRange

    public init(
        category: FindingsCategory = .all,
        nameQuery: String = "",
        sizeRange: FindingsSizeRange = FindingsSizeRange(minimumMB: nil, maximumMB: nil)
    ) {
        self.category = category
        self.nameQuery = nameQuery.trimmingCharacters(in: .whitespaces)
        self.sizeRange = sizeRange
    }

    public var isActive: Bool {
        category != .all
            || !nameQuery.isEmpty
            || sizeRange.isActive
    }

    /// Проверка одного кандидата; входной массив не изменяется.
    public func matches(_ candidate: DeletedFileCandidate) -> Bool {
        if category != .all,
           FindingsCategory.category(forDisplayName: candidate.displayName) != category {
            return false
        }
        if !nameQuery.isEmpty {
            let query = nameQuery.lowercased()
            if !candidate.displayName.lowercased().contains(query) {
                return false
            }
        }
        if sizeRange.isUnrepresentable {
            // Непредставимый диапазон (прямое конструирование мимо parse)
            // не снимает размерное ограничение, а исключает все находки:
            // ошибочный запрос не может расширить выдачу.
            return false
        }
        if let range = sizeRange.byteRange {
            // Неизвестный размер при активном пороге исключается явно.
            guard let expected = candidate.expectedSize else { return false }
            if expected < range.lower || expected > range.upper {
                return false
            }
        }
        return true
    }

    /// Отфильтрованный список: исходный массив не меняется, порядок найденных
    /// записей сохраняется.
    public func apply(to candidates: [DeletedFileCandidate]) -> [DeletedFileCandidate] {
        guard isActive else { return candidates }
        return candidates.filter { matches($0) }
    }
}
