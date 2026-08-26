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

func TestHistory(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OMARCHY_WORKING_MEMORY_DIR", filepath.Join(dir, "data"))

	s, err := Open()
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	if err := s.Save("first note\n"); err != nil {
		t.Fatalf("Save 1: %v", err)
	}
	if _, err := s.Commit(); err != nil {
		t.Fatalf("Commit 1: %v", err)
	}

	if err := s.Save("second note\n"); err != nil {
		t.Fatalf("Save 2: %v", err)
	}
	if _, err := s.Commit(); err != nil {
		t.Fatalf("Commit 2: %v", err)
	}

	log, err := s.Log()
	if err != nil {
		t.Fatalf("Log: %v", err)
	}
	if len(log) != 2 {
		t.Fatalf("expected 2 commits, got %d: %+v", len(log), log)
	}
	if log[0].Message == "" || log[1].Message == "" {
		t.Fatalf("expected non-empty preview messages: %+v", log)
	}
	// newest first
	if !log[0].Time.After(log[1].Time) && log[0].Time != log[1].Time {
		t.Fatalf("expected newest-first order: %+v", log)
	}

	oldContent, err := s.ShowAt(log[1].Hash)
	if err != nil {
		t.Fatalf("ShowAt: %v", err)
	}
	if oldContent != "first note\n" {
		t.Fatalf("ShowAt mismatch: %q", oldContent)
	}

	if err := s.RestoreAt(log[1].Hash, log[1].Time); err != nil {
		t.Fatalf("RestoreAt: %v", err)
	}
	restored, err := s.Load()
	if err != nil || restored != "first note\n" {
		t.Fatalf("post-restore content mismatch: %q err=%v", restored, err)
	}

	log2, err := s.Log()
	if err != nil {
		t.Fatalf("Log after restore: %v", err)
	}
	if len(log2) != 3 {
		t.Fatalf("expected restore to add a 3rd commit, got %d", len(log2))
	}
}
