package document

type Document interface {
	PageCount() int
	Page(pageNumber int) (Page, error)
	Close() error
}

type Page struct {
	Number int
	Text   string
	Layout string
}
