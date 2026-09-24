import Darwin
import Foundation
import RecoveryCore

struct UserFacingFailure: Equatable {
    let title: String
    let message: String

    static func make(from error: Error) -> UserFacingFailure {
        if containsNoSpaceError(error) {
            return UserFacingFailure(
                title: "Недостаточно места",
                message: "В папке результата закончилось свободное место. Освободите место или выберите другой диск. Уже созданные файлы сохранены."
            )
        }
        if let error = error as? DeletedFilesError { return deletedFiles(error) }
        if let error = error as? VideoRepairError { return video(error) }
        return UserFacingFailure(
            title: "Не удалось завершить операцию",
            message: "Произошла непредвиденная ошибка. Технические сведения сохранены в подробном логе."
        )
    }

    private static func deletedFiles(_ error: DeletedFilesError) -> UserFacingFailure {
        switch error {
        case .outputFolderMissing, .outputFolderNotWritable:
            UserFacingFailure(title: "Папка результата недоступна", message: error.localizedDescription)
        case .outputOnSource:
            UserFacingFailure(title: "Нужен другой диск", message: error.localizedDescription)
        case .imageMissing:
            UserFacingFailure(title: "Источник исчез", message: "Выбранный образ больше недоступен. Выберите его заново.")
        case .imageNotRegularFile:
            UserFacingFailure(title: "Неверный источник", message: "Укажите обычный файл образа, а не папку или устройство.")
        case .invalidDriveSource:
            UserFacingFailure(title: "Неверный источник", message: "Проверьте идентификатор накопителя и ожидаемые имя и размер, затем запустите команду заново.")
        case .sourceUnavailable, .sourceReadFailed:
            UserFacingFailure(title: "Накопитель отключён", message: error.localizedDescription)
        case .sourceChanged:
            UserFacingFailure(title: "Источник изменился", message: error.localizedDescription)
        case .authorizationDenied:
            UserFacingFailure(
                title: "Доступ macOS не предоставлен",
                message: "RecoveryApp не получил разрешение только для чтения. Повторите запуск и подтвердите системный запрос."
            )
        case .toolMissing(let name):
            UserFacingFailure(
                title: "Компонент приложения повреждён",
                message: "Встроенный инструмент \(name) отсутствует или повреждён. Переустановите RecoveryApp из проверенного архива."
            )
        case .unsupportedImage:
            UserFacingFailure(title: "Формат не поддерживается", message: error.localizedDescription)
        case .nothingSelected:
            UserFacingFailure(title: "Файлы не выбраны", message: error.localizedDescription)
        case .outputSpaceExhausted:
            UserFacingFailure(
                title: "Недостаточно места",
                message: "В папке результата закончилось свободное место. Освободите место или выберите другой диск. Уже созданные файлы сохранены."
            )
        case .launchFailed, .toolFailed:
            UserFacingFailure(
                title: "Инструмент не смог завершить работу",
                message: "Операция завершилась с технической ошибкой. Подробности доступны в журнале."
            )
        case .cancelled:
            UserFacingFailure(title: "Операция остановлена", message: "Уже найденные файлы сохранены.")
        }
    }

    private static func video(_ error: VideoRepairError) -> UserFacingFailure {
        switch error {
        case .sameInputFiles:
            UserFacingFailure(title: "Нужны два разных видео", message: error.localizedDescription)
        case .inputMissing:
            UserFacingFailure(title: "Исходный файл исчез", message: "Один из выбранных файлов больше недоступен. Выберите файлы заново.")
        case .inputNotRegularFile:
            UserFacingFailure(title: "Неверный источник", message: "Выберите обычные видеофайлы, а не папки или устройства.")
        case .inputNotReadable:
            UserFacingFailure(title: "Файл недоступен", message: "macOS не разрешила чтение одного из выбранных файлов. Проверьте права доступа.")
        case .outputFolderMissing, .outputFolderNotWritable:
            UserFacingFailure(title: "Папка результата недоступна", message: error.localizedDescription)
        case .outputFolderIsFile:
            UserFacingFailure(title: "Папка результата недоступна", message: "Путь результата указывает на файл. Выберите отдельную папку на другом диске.")
        case .resultOnSourceVolume:
            UserFacingFailure(title: "Нужен другой диск", message: error.localizedDescription)
        case .volumeIdentityUnknown:
            UserFacingFailure(title: "Носитель не определён", message: "Не удалось надёжно определить носитель результата. Для безопасности выберите папку на другом диске и повторите попытку.")
        case .toolMissing:
            UserFacingFailure(
                title: "Компонент приложения повреждён",
                message: "Встроенный untrunc отсутствует или повреждён. Переустановите RecoveryApp из проверенного архива."
            )
        case .resultMissing:
            UserFacingFailure(title: "Видео не создано", message: error.localizedDescription)
        case .outputSpaceExhausted:
            UserFacingFailure(
                title: "Недостаточно места",
                message: "В папке результата закончилось свободное место. Освободите место или выберите другой диск."
            )
        case .launchFailed, .toolFailed:
            UserFacingFailure(
                title: "Видео не удалось восстановить",
                message: "untrunc не смог завершить обработку. Технические сведения доступны в подробном логе."
            )
        case .cancelled:
            UserFacingFailure(title: "Операция остановлена", message: "Исходные видео не изменялись.")
        }
    }

    private static func containsNoSpaceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           containsNoSpaceError(underlying) { return true }
        let description = nsError.localizedDescription.lowercased()
        return description.contains("no space left") || description.contains("недостаточно места")
    }
}
