package reader

import (
	"fmt"
	"termreader/internal/document"
)

type Reader struct {
	document    document.Document
	currentPage int
}

func New(doc document.Document) *Reader {
	if doc == nil {
		panic("reader.New: nil document")
	}

	return &Reader{
		document:    doc,
		currentPage: 1,
	}
}

func (r *Reader) PageCount() int {
	return r.document.PageCount()
}

func (r *Reader) CurrentPageNumber() int {
	return r.currentPage
}

func (r *Reader) CurrentPage() (document.Page, error) {
	return r.document.Page(r.currentPage)
}

func (r *Reader) Next() {
	if r.currentPage < r.PageCount() {
		r.currentPage++
	}
}

func (r *Reader) Previous() {
	if r.currentPage > 1 {
		r.currentPage--
	}
}

// GoToPage sets the reader's current page to the given number.
// It returns an error if the requested page is out of bounds.
func (r *Reader) GoToPage(page int) error {
	if page < 1 || page > r.PageCount() {
		return fmt.Errorf("page %d out of range", page)
	}
	r.currentPage = page
	return nil
}
