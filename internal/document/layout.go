package document

import (
	"math"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	pdftext "github.com/giraffesyo/pdf"
)

type positionedGlyph struct {
	text string
	x    float64
	y    float64
}

func RenderLayout(page pdftext.Page, width int) string {
	if width < 20 {
		width = 80
	}

	box := page.CropBox
	if box.MaxX <= box.MinX || box.MaxY <= box.MinY {
		box = page.MediaBox
	}

	pageWidth := box.MaxX - box.MinX
	pageHeight := box.MaxY - box.MinY

	if pageWidth <= 0 || pageHeight <= 0 || len(page.Glyphs) == 0 {
		return page.Text()
	}

	glyphs := make([]positionedGlyph, 0, len(page.Glyphs))

	for _, glyph := range page.Glyphs {
		if glyph.Text == "" {
			continue
		}

		glyphs = append(glyphs, positionedGlyph{
			text: glyph.Text,
			x:    glyph.X - box.MinX,
			y:    box.MaxY - glyph.Y,
		})
	}

	if len(glyphs) == 0 {
		return page.Text()
	}

	// Sort from top to bottom, then left to right.
	sort.SliceStable(glyphs, func(i, j int) bool {
		if math.Abs(glyphs[i].y-glyphs[j].y) > 2 {
			return glyphs[i].y < glyphs[j].y
		}
		return glyphs[i].x < glyphs[j].x
	})

	// Group glyphs into visual lines using PDF coordinates.
	var lines [][]positionedGlyph

	for _, glyph := range glyphs {
		added := false

		if len(lines) > 0 {
			last := lines[len(lines)-1]
			averageY := 0.0

			for _, g := range last {
				averageY += g.y
			}
			averageY /= float64(len(last))

			// Adjust this tolerance if lines merge or split incorrectly.
			if math.Abs(glyph.y-averageY) <= 3 {
				lines[len(lines)-1] = append(last, glyph)
				added = true
			}
		}

		if !added {
			lines = append(lines, []positionedGlyph{glyph})
		}
	}

	var output strings.Builder

	// Use the PDF's horizontal coordinates to preserve alignment.
	cellWidth := pageWidth / float64(width)

	var previousY float64

	for lineIndex, line := range lines {
		sort.SliceStable(line, func(i, j int) bool {
			return line[i].x < line[j].x
		})

		if len(line) == 0 {
			continue
		}

		lineY := 0.0
		for _, glyph := range line {
			lineY += glyph.y
		}
		lineY /= float64(len(line))

		// Preserve larger vertical gaps between paragraphs.
		if lineIndex > 0 {
			gap := lineY - previousY
			if gap > 18 {
				output.WriteString("\n")
			}
		}

		var text strings.Builder
		lastX := line[0].x
		column := int(math.Round(line[0].x / cellWidth))

		if column < 0 {
			column = 0
		}
		if column > width-1 {
			column = width - 1
		}

		text.WriteString(strings.Repeat(" ", column))
		text.WriteString(line[0].text)

		lastX += estimateGlyphWidth(line[0].text, cellWidth)

		for _, glyph := range line[1:] {
			gap := glyph.x - lastX

			// Insert spaces only for a meaningful physical gap.
			spaces := int(math.Round(gap / cellWidth))
			if gap > cellWidth*0.45 && spaces < 1 {
				spaces = 1
			}
			if spaces < 0 {
				spaces = 0
			}
			if spaces > width {
				spaces = width
			}

			text.WriteString(strings.Repeat(" ", spaces))
			text.WriteString(glyph.text)

			lastX = glyph.x + estimateGlyphWidth(glyph.text, cellWidth)
		}

		output.WriteString(strings.TrimRight(text.String(), " "))
		output.WriteByte('\n')

		previousY = lineY
	}

	return strings.TrimRight(output.String(), "\n")
}

func estimateGlyphWidth(text string, cellWidth float64) float64 {
	// Approximate terminal width from Unicode characters.
	// This is only a fallback because PDF glyph widths are font-dependent.
	count := 0

	for _, r := range text {
		if unicode.Is(unicode.Mn, r) {
			continue
		}
		count += utf8.RuneCountInString(string(r))
	}

	return float64(count) * cellWidth
}
