QT += core gui qml quick quickcontrols2 concurrent network

CONFIG += c++17 release
TARGET = omarchy-working-memory
TEMPLATE = app

HEADERS += \
    src/backend.h \
    src/capture.h \
    src/cards.h \
    src/gitstore.h

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/capture.cpp \
    src/cards.cpp \
    src/gitstore.cpp

RESOURCES += src/resources.qrc

# macOS: a menu-bar .app bundle (see src/macos.h, macos/).
macx {
    HEADERS += src/macos.h
    OBJECTIVE_SOURCES += src/macos.mm
    QMAKE_OBJECTIVE_CFLAGS += -fobjc-arc
    LIBS += -framework AppKit -framework Carbon -framework ServiceManagement
    # Homebrew's Qt is itself built for macOS 26, so that's the real floor
    # of any app linked against it. Qt's own installer (qt.io) builds for
    # older releases, if the app ever needs to run on one.
    QMAKE_MACOSX_DEPLOYMENT_TARGET = 26.0
    QMAKE_INFO_PLIST = macos/Info.plist
    ICON = macos/AppIcon.icns
}
