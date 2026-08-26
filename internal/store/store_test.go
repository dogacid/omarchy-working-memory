package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenSaveCommit(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OMARCHY_WORKING_MEMORY_DIR", filepath.Join(dir, "data"))

	s, err := Open()
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.Dir(), ".git")); err != nil {
		t.Fatalf("expected git repo to exist: %v", err)
	}

	if err := s.Save("first note\n"); err != nil {
		t.Fatalf("Save: %v", err)
	}
	committed, err := s.Commit()
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}
	if !committed {
		t.Fatal("expected first commit to happen")
	}

	committed, err = s.Commit()
	if err != nil {
		t.Fatalf("Commit (no-op): %v", err)
	}
	if committed {
		t.Fatal("expected second commit to be a no-op")
	}

	if err := s.Save("first note\nsecond line\n"); err != nil {
		t.Fatalf("Save 2: %v", err)
	}
	committed, err = s.Commit()
	if err != nil {
		t.Fatalf("Commit 2: %v", err)
	}
	if !committed {
		t.Fatal("expected third commit (real change) to happen")
	}

	content, err := s.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if content != "first note\nsecond line\n" {
		t.Fatalf("unexpected content: %q", content)
	}

	// Reopen against the same dir: should not re-init or lose the file.
	s2, err := Open()
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	content2, err := s2.Load()
	if err != nil || content2 != content {
		t.Fatalf("reopen content mismatch: %q err=%v", content2, err)
	}
}
