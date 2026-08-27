#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickStyle>
#include <QIcon>
#include <cstdio>

#include "backend.h"

int main(int argc, char *argv[]) {
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

    return app.exec();
}
