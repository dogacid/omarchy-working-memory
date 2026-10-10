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
