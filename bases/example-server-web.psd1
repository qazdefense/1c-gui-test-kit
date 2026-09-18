@{
    # Клиент-серверная база с пользователем и веб-публикацией - доступны оба режима.
    # Для веб-клиента пользователь должен быть прописан в строке соединения
    # публикации (Usr=/Pwd= в default.vrd): форму входа 1С навык web-test не заполняет.
    # Используйте отдельного тестового пользователя: пароль виден в командной
    # строке процесса 1cv8.exe.
    ConnectionType = "Server"

    Server = @{
        Server = "localhost"
        Ref    = "demo"
    }

    PlatformPath = "C:\Program Files\1cv8\8.3.27.1989\bin\1cv8.exe"

    Auth = @{
        User     = "GuiTest"
        Password = ""
    }

    WebUrl = "http://localhost/demo/"
}
