// Package clip shells out to wl-clipboard so paste/copy hit the real
// Wayland system clipboard, regardless of how the terminal emulator
// otherwise handles selection.
package clip

import (
	"bytes"
	"fmt"
	"os/exec"
)

// Paste returns the current contents of the system clipboard.
func Paste() (string, error) {
	out, err := exec.Command("wl-paste", "--no-newline").Output()
	if err != nil {
		return "", fmt.Errorf("wl-paste: %w", err)
	}
	return string(out), nil
}

// Copy sets the system clipboard to text.
func Copy(text string) error {
	cmd := exec.Command("wl-copy")
	cmd.Stdin = bytes.NewReader([]byte(text))
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wl-copy: %w", err)
	}
	return nil
}
