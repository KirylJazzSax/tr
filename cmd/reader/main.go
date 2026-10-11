package main

import (
	"fmt"
	"os"
	"path/filepath"

	"termreader/internal/document"
	"termreader/internal/reader"
	"termreader/internal/terminal"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reader <book.pdf>")
		os.Exit(2)
	}

	path := os.Args[1]

	doc, err := document.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	defer func() {
		if err := doc.Close(); err != nil {
			fmt.Fprintln(os.Stderr, "close PDF:", err)
		}
	}()

	r := reader.New(doc)

	app := terminal.New(
		r,
		os.Stdin,
		os.Stdout,
	)

	if err := app.Run(filepath.Base(path)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
