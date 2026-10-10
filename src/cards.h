#pragma once

#include <QString>
#include <QStringList>

// Luhmann-style card numbering ("Folgezettel"), as pure functions over ID
// strings — no I/O, so GitStore and Backend can share it and it's easy to
// reason about on its own.
//
// An ID alternates runs of digits and lowercase letters, always starting
// with digits: "1", "1a", "1a1", "1b", "12c3". Each run is one segment.
// Numbers are fixed once given — a card is never renumbered — so position
// in the sequence is expressed entirely by the ID:
//
//   - continuing a line of thought increments the last segment
//     (1 → 2, 1a → 1b, 1a1 → 1a2);
//   - branching off a card appends a new segment
//     (1 → 1a, 1a → 1a1).
//
// Sorting by segment (prefix first) gives the slip-box order Luhmann's
// drawer had: 1, 1a, 1a1, 1a2, 1b, 2 — a branch always files directly
// behind the card it grew from, ahead of that card's next sibling.
namespace Cards {

// Empty if id isn't a well-formed card ID (no leading zeros, digits first,
// only digits and lowercase a-z).
QStringList segments(const QString &id);
bool isValidId(const QString &id);
// Number of segments minus one: 0 for "1", 1 for "1a", 2 for "1a1".
int depth(const QString &id);
// Slip-box order (see above). Invalid IDs sort after valid ones.
bool lessThan(const QString &a, const QString &b);

// The next free top-level number: one past the highest existing top-level
// segment, or "1" for a topic with no cards yet.
QString nextTopLevel(const QStringList &existing);
// "Add a card after this one", Luhmann's rule: the next sibling if that
// number is still free, otherwise a branch (since the card that already
// holds the sibling number can't be moved out of the way).
QString continueAfter(const QString &id, const QStringList &existing);
// Always a branch: the next free child of id, after any it already has
// (1 → 1a; 1 → 1b once 1a exists).
QString branchFrom(const QString &id, const QStringList &existing);

}
