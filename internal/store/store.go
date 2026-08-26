// Package store manages the working-memory text file and its git history.
package store

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
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

	msg := "update " + time.Now().Format("2006-01-02 15:04")
	if err := s.git("commit", "-q", "-m", msg); err != nil {
		return false, fmt.Errorf("git commit: %w", err)
	}
	return true, nil
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
