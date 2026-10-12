#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickStyle>
#include <QIcon>
#include <cstdio>

#include "backend.h"
#include "capture.h"

#include <QCoreApplication>
#include <QQuickWindow>
#include <cstring>

#ifdef Q_OS_MACOS
#include "macos.h"
#endif

int main(int argc, char *argv[]) {
    // Started by the browser for the capture extension (see capture.h):
    // no window, no GUI at all — just JSON over stdin/stdout. Chromium also
    // passes the calling extension's origin as an argument, otherwise
    // ignored (the host manifest's allowed_origins already restricts who can
    // call) — but on macOS the manifest points straight at the binary inside
    // the .app, with no wrapper script to add --native-host, so that origin
    // argument is what says it's the browser starting us.
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--native-host") == 0
            || std::strncmp(argv[i], "chrome-extension://", 19) == 0) {
            QCoreApplication app(argc, argv);
            return Capture::runNativeHost();
        }
    }

#ifdef Q_OS_MACOS
    // Started from Finder/launchd, PATH is just /usr/bin:/bin:/usr/sbin:/sbin,
    // so `git` would be Apple's /usr/bin shim rather than the Homebrew one a
    // terminal uses (and that ~/.gitconfig may assume).
    qputenv("PATH", "/opt/homebrew/bin:/usr/local/bin:" + qgetenv("PATH"));
#endif

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("omarchy-working-memory"));
    // Matches the class the Hyprland window rule (hypr/working-memory.lua)
    // keys off of — see bin/omarchy-working-memory-toggle. Deliberately
    // NOT prefixed "org.omarchy." — Omarchy's terminal-tag rule
    // (apps/terminals.lua) matches that prefix unconditionally to tag
    // Omarchy-launched TUIs as terminals, which made Super+C send the
    // terminal-style Ctrl+Insert instead of literal Ctrl+C (confirmed:
    // clipboard stayed unchanged after Super+C while tagged "terminal*").
    // A real Qt widget only binds literal Ctrl+C, so avoid that tag.
    app.setDesktopFileName(QStringLiteral("omarchy-working-memory"));
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("accessories-text-editor")));

    QQuickStyle::setStyle(QStringLiteral("Basic"));

    Backend backend;
    if (!backend.start()) {
        std::fprintf(stderr, "omarchy-working-memory: %s\n", qUtf8Printable(backend.lastError()));
        return 1;
    }

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::warnings, &app,
        [](const QList<QQmlError> &warnings) {
            for (const QQmlError &w : warnings)
                qWarning().noquote() << w.toString();
        });
    engine.rootContext()->setContextProperty(QStringLiteral("backend"), &backend);

    engine.load(QUrl(QStringLiteral("qrc:/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return 1;

#ifdef Q_OS_MACOS
    // No compositor to relaunch the app on Super+N, so it stays running:
    // closing the window (Cmd+W) only hides it — onClosing still saves,
    // commits and starts the push — and the hotkey or menu-bar item brings
    // it back (see macos.h).
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    app.setQuitOnLastWindowClosed(false);
    // Shown before activating, so the applicationStateChanged handler
    // below sees it visible and doesn't open it a second time.
    auto open = [window, &backend] {
        if (!window->isVisible()) {
            backend.windowReopened();
            window->show();
        }
        window->raise();
        MacOS::activate();
        window->requestActivate();
    };
    MacOS::install(open, [] { QCoreApplication::quit(); });
    // Opening the app again from Spotlight/Finder while it's running just
    // activates it: treat that as a request for the window too.
    QObject::connect(&app, &QGuiApplication::applicationStateChanged, window,
        [window, open](Qt::ApplicationState state) {
            if (state == Qt::ApplicationActive && !window->isVisible())
                open();
        });
    // Quitting from the menu bar with the window open skips onClosing.
    QObject::connect(&app, &QCoreApplication::aboutToQuit, window, [window, &backend] {
        if (window->isVisible())
            backend.save();
    });
#endif

    return app.exec();
}
