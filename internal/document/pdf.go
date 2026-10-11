package document

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	pdftext "github.com/giraffesyo/pdf"
)

type pdfDocument struct {
	doc    *pdftext.Document
	closed bool
}

func Open(path string) (Document, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open PDF %q: %w", path, err)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat PDF %q: %w", path, err)
	}

	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("open PDF %q: not a regular file", path)
	}
	if info.Size() == 0 {
		return nil, fmt.Errorf("open PDF %q: file is empty", path)
	}

	doc, err := pdftext.Extract(context.Background(), file, info.Size())
	if err != nil {
		return nil, fmt.Errorf("extract PDF %q: %w", path, err)
	}
	if len(doc.Pages) == 0 {
		return nil, fmt.Errorf("open PDF %q: document has no pages", path)
	}

	return &pdfDocument{doc: doc}, nil
}

func (d *pdfDocument) PageCount() int {
	if d == nil || d.closed || d.doc == nil {
		return 0
	}
	return len(d.doc.Pages)
}

func (d *pdfDocument) Page(pageNumber int) (Page, error) {
	if d == nil || d.closed || d.doc == nil {
		return Page{}, errors.New("document is closed")
	}

	if pageNumber < 1 || pageNumber > len(d.doc.Pages) {
		return Page{}, fmt.Errorf(
			"invalid page number %d: expected 1..%d",
			pageNumber,
			len(d.doc.Pages),
		)
	}

	text := cleanText(d.doc.Pages[pageNumber-1].Text())

	return Page{
		Number: pageNumber,
		Text:   text,
		Layout: RenderLayout(d.doc.Pages[pageNumber-1], 80),
	}, nil
}

func (d *pdfDocument) Close() error {
	if d == nil || d.closed {
		return nil
	}

	d.closed = true
	d.doc = nil
	return nil
}

func cleanText(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")

	lines := strings.Split(text, "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " \t")
	}

	return strings.TrimSpace(strings.Join(lines, "\n"))
}
