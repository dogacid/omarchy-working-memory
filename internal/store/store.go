// Package store manages the working-memory text file and its git history.
package store

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

const fileName = "working-memory.txt"

// Store owns the on-disk working-memory file and the git repo that
// versions it.
type Store struct {
	dir  string
	path string
}

// Open resolves the data directory (defaulting to
// $XDG_DATA_HOME/omarchy-working-memory, or ~/.local/share/... when unset),
// ensuring the directory, the git repo, and the note file all exist.
func Open() (*Store, error) {
	dir, err := dataDir()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	s := &Store{dir: dir, path: filepath.Join(dir, fileName)}

	if _, err := os.Stat(filepath.Join(dir, ".git")); os.IsNotExist(err) {
		if err := s.git("init", "-q"); err != nil {
			return nil, fmt.Errorf("git init: %w", err)
		}
		if err := s.ensureIdentity(); err != nil {
			return nil, err
		}
	}

	if _, err := os.Stat(s.path); os.IsNotExist(err) {
		if err := os.WriteFile(s.path, nil, 0o644); err != nil {
			return nil, fmt.Errorf("create note file: %w", err)
		}
	}

	return s, nil
}

func dataDir() (string, error) {
	if v := os.Getenv("OMARCHY_WORKING_MEMORY_DIR"); v != "" {
		return v, nil
	}
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "omarchy-working-memory"), nil
}

// Path returns the absolute path to the working-memory file.
func (s *Store) Path() string { return s.path }

// Dir returns the data directory (the git repo root).
func (s *Store) Dir() string { return s.dir }

// Load reads the current file contents.
func (s *Store) Load() (string, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// Save writes content to disk atomically (write-tmp then rename).
func (s *Store) Save(content string) error {
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Commit stages and commits the note file if it has changes. It is a no-op
// (returns false, nil) when there is nothing to commit.
func (s *Store) Commit() (committed bool, err error) {
	content, _ := s.Load() // best-effort; a preview isn't worth failing the commit over
	msg := previewLine(content) + "  (" + time.Now().Format("2006-01-02 15:04") + ")"
	return s.commitWithMessage(msg)
}

func (s *Store) commitWithMessage(msg string) (committed bool, err error) {
	if err := s.git("add", fileName); err != nil {
		return false, fmt.Errorf("git add: %w", err)
	}

	out, err := s.gitOutput("diff", "--cached", "--name-only")
	if err != nil {
		return false, fmt.Errorf("git diff: %w", err)
	}
	if strings.TrimSpace(out) == "" {
		return false, nil
	}

	if err := s.git("commit", "-q", "-m", msg); err != nil {
		return false, fmt.Errorf("git commit: %w", err)
	}
	return true, nil
}

// previewLine picks a short, human-recognizable snippet for the commit
// message — the point of it is browsability: scanning `git log` (or the
// app's history picker) for "that thing about the car insurance" only works
// if the message carries actual content, not just a timestamp.
func previewLine(content string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		const maxRunes = 60
		if utf8.RuneCountInString(line) > maxRunes {
			r := []rune(line)
			return string(r[:maxRunes]) + "…"
		}
		return line
	}
	return "(empty)"
}

// Commit is one point in the note's history.
type Commit struct {
	Hash    string
	Time    time.Time
	Message string
}

// Log returns every commit touching the note file, newest first.
func (s *Store) Log() ([]Commit, error) {
	const sep = "\x1f" // unit separator: won't collide with real message text
	out, err := s.gitOutput("log", "--format=%H"+sep+"%cI"+sep+"%s", "--", fileName)
	if err != nil {
		// A brand new repo with no commits yet exits non-zero here; that's
		// an empty history, not a failure.
		if strings.TrimSpace(out) == "" {
			return nil, nil
		}
		return nil, fmt.Errorf("git log: %w", err)
	}

	var commits []Commit
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, sep, 3)
		if len(parts) != 3 {
			continue
		}
		t, err := time.Parse(time.RFC3339, parts[1])
		if err != nil {
			continue
		}
		commits = append(commits, Commit{Hash: parts[0], Time: t, Message: parts[2]})
	}
	return commits, nil
}

// ShowAt returns the note's content exactly as it was at the given commit.
func (s *Store) ShowAt(hash string) (string, error) {
	out, err := s.gitOutput("show", hash+":"+fileName)
	if err != nil {
		return "", fmt.Errorf("git show: %w", err)
	}
	return out, nil
}

// RestoreAt makes the content at the given commit current again — writing
// it to the live file and creating a new commit on top, same as any other
// edit. Nothing from history is ever rewritten or lost: the state right
// before a restore stays reachable in the log like any other past version.
func (s *Store) RestoreAt(hash string, at time.Time) error {
	content, err := s.ShowAt(hash)
	if err != nil {
		return err
	}
	if err := s.Save(content); err != nil {
		return err
	}
	msg := fmt.Sprintf("restore from %s (%s): %s", shortHash(hash), at.Format("2006-01-02 15:04"), previewLine(content))
	_, err = s.commitWithMessage(msg)
	return err
}

func shortHash(hash string) string {
	if len(hash) > 8 {
		return hash[:8]
	}
	return hash
}

// ensureIdentity sets a local commit identity when the user has none
// configured at all (global or system), so the very first commit doesn't
// fail on a fresh machine. It never overrides an identity the user already
// has.
func (s *Store) ensureIdentity() error {
	if err := s.git("config", "user.name"); err == nil {
		return nil // already configured (local, global, or system)
	}
	if err := s.git("config", "user.name", "Omarchy Working Memory"); err != nil {
		return err
	}
	return s.git("config", "user.email", "working-memory@localhost")
}

func (s *Store) git(args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", s.dir}, args...)...)
	return cmd.Run()
}

func (s *Store) gitOutput(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", s.dir}, args...)...)
	out, err := cmd.Output()
	return string(out), err
}
