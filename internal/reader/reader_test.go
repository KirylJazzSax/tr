package reader

import (
	"errors"
	"testing"

	"termreader/internal/document"
)

type fakeDocument struct {
	pages []document.Page
}

func (f *fakeDocument) PageCount() int {
	return len(f.pages)
}

func (f *fakeDocument) Page(pageNumber int) (document.Page, error) {
	if pageNumber < 1 || pageNumber > len(f.pages) {
		return document.Page{}, errors.New("invalid page")
	}

	return f.pages[pageNumber-1], nil
}

func (f *fakeDocument) Close() error {
	return nil
}

func newFakeDocument() *fakeDocument {
	return &fakeDocument{
		pages: []document.Page{
			{Number: 1, Text: "Page One"},
			{Number: 2, Text: "Page Two"},
			{Number: 3, Text: "Page Three"},
		},
	}
}

func TestNewStartsAtPageOne(t *testing.T) {
	r := New(newFakeDocument())

	if got := r.CurrentPageNumber(); got != 1 {
		t.Fatalf("expected page 1, got %d", got)
	}

	if got := r.PageCount(); got != 3 {
		t.Fatalf("expected 3 pages, got %d", got)
	}
}

func TestNext(t *testing.T) {
	r := New(newFakeDocument())

	r.Next()

	if got := r.CurrentPageNumber(); got != 2 {
		t.Fatalf("expected page 2, got %d", got)
	}

	r.Next()

	if got := r.CurrentPageNumber(); got != 3 {
		t.Fatalf("expected page 3, got %d", got)
	}

	r.Next()

	if got := r.CurrentPageNumber(); got != 3 {
		t.Fatalf("expected to remain on page 3, got %d", got)
	}
}

func TestPrevious(t *testing.T) {
	r := New(newFakeDocument())

	r.Next()
	r.Next()

	r.Previous()

	if got := r.CurrentPageNumber(); got != 2 {
		t.Fatalf("expected page 2, got %d", got)
	}

	r.Previous()

	if got := r.CurrentPageNumber(); got != 1 {
		t.Fatalf("expected page 1, got %d", got)
	}

	r.Previous()

	if got := r.CurrentPageNumber(); got != 1 {
		t.Fatalf("expected to remain on page 1, got %d", got)
	}
}

func TestCurrentPage(t *testing.T) {
	r := New(newFakeDocument())

	page, err := r.CurrentPage()
	if err != nil {
		t.Fatal(err)
	}

	if page.Number != 1 {
		t.Fatalf("expected page 1, got %d", page.Number)
	}

	r.Next()

	page, err = r.CurrentPage()
	if err != nil {
		t.Fatal(err)
	}

	if page.Number != 2 {
		t.Fatalf("expected page 2, got %d", page.Number)
	}
}
