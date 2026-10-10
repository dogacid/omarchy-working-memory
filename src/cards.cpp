#include "cards.h"

namespace {

bool isDigitRun(const QString &seg) {
    return !seg.isEmpty() && seg.at(0).isDigit();
}

// Letter runs count bijectively in base 26, spreadsheet-column style:
// a..z, aa..az, ba..zz, aaa... — so there's always a next one, and a
// longer run always sorts after a shorter one.
QString nextLetters(const QString &seg) {
    QString s = seg;
    int i = s.size() - 1;
    while (i >= 0) {
        if (s.at(i) != QLatin1Char('z')) {
            s[i] = QChar(s.at(i).unicode() + 1);
            return s;
        }
        s[i] = QLatin1Char('a');
        --i;
    }
    return QLatin1Char('a') + s;
}

QString nextSegment(const QString &seg) {
    if (isDigitRun(seg))
        return QString::number(seg.toLongLong() + 1);
    return nextLetters(seg);
}

int compareSegment(const QString &a, const QString &b) {
    if (isDigitRun(a)) {
        const qlonglong x = a.toLongLong(), y = b.toLongLong();
        return x < y ? -1 : (x > y ? 1 : 0);
    }
    if (a.size() != b.size())
        return a.size() < b.size() ? -1 : 1;
    return a.compare(b);
}

}

namespace Cards {

QStringList segments(const QString &id) {
    QStringList out;
    if (id.isEmpty() || !id.at(0).isDigit())
        return {};
    QString cur;
    for (const QChar &c : id) {
        const bool digit = c.isDigit() && c.unicode() < 128;
        const bool letter = c >= QLatin1Char('a') && c <= QLatin1Char('z');
        if (!digit && !letter)
            return {};
        if (!cur.isEmpty() && isDigitRun(cur) != digit) {
            out.append(cur);
            cur.clear();
        }
        cur += c;
    }
    out.append(cur);
    for (const QString &seg : out) {
        if (isDigitRun(seg) && seg.at(0) == QLatin1Char('0'))
            return {}; // "01" would otherwise be a second spelling of "1"
    }
    return out;
}

bool isValidId(const QString &id) {
    return !segments(id).isEmpty();
}

int depth(const QString &id) {
    return qMax(0, int(segments(id).size()) - 1);
}

bool lessThan(const QString &a, const QString &b) {
    const QStringList sa = segments(a), sb = segments(b);
    if (sa.isEmpty() || sb.isEmpty()) {
        if (sa.isEmpty() != sb.isEmpty())
            return !sa.isEmpty();
        return a < b;
    }
    const int n = qMin(sa.size(), sb.size());
    for (int i = 0; i < n; ++i) {
        const int c = compareSegment(sa.at(i), sb.at(i));
        if (c != 0)
            return c < 0;
    }
    return sa.size() < sb.size();
}

QString nextTopLevel(const QStringList &existing) {
    qlonglong highest = 0;
    for (const QString &id : existing) {
        const QStringList segs = segments(id);
        if (!segs.isEmpty())
            highest = qMax(highest, segs.first().toLongLong());
    }
    return QString::number(highest + 1);
}

QString continueAfter(const QString &id, const QStringList &existing) {
    QStringList segs = segments(id);
    if (segs.isEmpty())
        return nextTopLevel(existing);
    segs.last() = nextSegment(segs.last());
    const QString sibling = segs.join(QString());
    if (!existing.contains(sibling))
        return sibling;
    return branchFrom(id, existing);
}

QString nextSibling(const QString &id) {
    QStringList segs = segments(id);
    if (segs.isEmpty())
        return QString();
    segs.last() = nextSegment(segs.last());
    return segs.join(QString());
}

QString reroot(const QString &id, const QString &from, const QString &to) {
    const QStringList segs = segments(id), fromSegs = segments(from), toSegs = segments(to);
    if (segs.isEmpty() || fromSegs.isEmpty() || toSegs.size() != fromSegs.size()
        || segs.size() < fromSegs.size() || segs.mid(0, fromSegs.size()) != fromSegs)
        return QString();
    return (toSegs + segs.mid(fromSegs.size())).join(QString());
}

QString branchFrom(const QString &id, const QStringList &existing) {
    const QStringList segs = segments(id);
    if (segs.isEmpty())
        return nextTopLevel(existing);

    // Children are exactly one segment longer and share this card's
    // segments as their prefix. The new branch goes after the last of them.
    QString lastChild;
    for (const QString &other : existing) {
        const QStringList o = segments(other);
        if (o.size() != segs.size() + 1 || o.mid(0, segs.size()) != segs)
            continue;
        if (lastChild.isEmpty() || lessThan(lastChild, other))
            lastChild = other;
    }

    QString candidate;
    if (lastChild.isEmpty()) {
        candidate = id + (isDigitRun(segs.last()) ? QStringLiteral("a") : QStringLiteral("1"));
    } else {
        QStringList c = segments(lastChild);
        c.last() = nextSegment(c.last());
        candidate = c.join(QString());
    }
    return candidate;
}

}
