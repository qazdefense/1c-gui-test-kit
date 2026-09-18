@{
    # Файловая база, без авторизации, без веб-публикации - только толстый/тонкий клиент.
    # Скопируйте в bases\<ИмяБазы>.psd1 и поправьте пути. Файлы bases\*.psd1
    # (кроме example-*) в .gitignore: в них пароли.
    ConnectionType = "File"

    File = @{
        Path = "D:\Bases\Demo"
    }

    PlatformPath = "C:\Program Files\1cv8\8.3.27.1989\bin\1cv8.exe"
}
