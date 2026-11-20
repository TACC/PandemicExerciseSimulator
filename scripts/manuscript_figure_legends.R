# Companion PDFs contain the prose legend for the matching manuscript PNG.
write_manuscript_legend <- function(figure_dir, stem, title, paragraphs) {
  page_width <- 8.5
  margin <- 0.6
  text_width <- page_width - 2 * margin
  body_gp <- grid::gpar(fontsize = 12, lineheight = 1.25, col = "#222222")
  heading_gp <- grid::gpar(fontsize = 12, fontface = "bold", col = "#222222")
  title_gp <- grid::gpar(fontsize = 17, fontface = "bold", col = "#222222")

  wrap <- function(paragraph) {
    words <- strsplit(paragraph, "[[:space:]]+")[[1]]
    lines <- character()
    line <- words[1]
    for (word in words[-1]) {
      candidate <- paste(line, word)
      width <- grid::convertWidth(grid::grobWidth(grid::textGrob(candidate, gp = body_gp)),
        "inches", valueOnly = TRUE)
      if (width > text_width) {
        lines <- c(lines, line)
        line <- word
      } else {
        line <- candidate
      }
    }
    c(lines, line)
  }
  wrap_paragraphs <- function() {
    grDevices::pdf(NULL, width = page_width, family = "Helvetica")
    on.exit(grDevices::dev.off())
    lapply(paragraphs, wrap)
  }
  lines <- wrap_paragraphs()
  headings <- names(paragraphs)
  if (is.null(headings)) headings <- rep("", length(lines))
  line_height <- 15 / 72
  paragraph_gap <- 0.14
  heading_height <- 0.26
  title_height <- 0.42
  height <- 2 * margin + title_height + sum(lengths(lines)) * line_height +
    sum(nzchar(headings)) * heading_height + (length(lines) - 1) * paragraph_gap

  path <- file.path(figure_dir, paste0(stem, "_legend.pdf"))
  grDevices::pdf(path, width = page_width, height = height, family = "Helvetica")
  on.exit(grDevices::dev.off())
  grid::grid.newpage()
  draw <- function(label, y, gp) {
    grid::grid.text(label, x = grid::unit(margin, "inches"), y = grid::unit(y, "inches"),
      just = c("left", "top"), gp = gp)
  }
  cursor <- height - margin
  draw(title, cursor, title_gp)
  cursor <- cursor - title_height
  for (i in seq_along(lines)) {
    if (nzchar(headings[i])) {
      draw(headings[i], cursor, heading_gp)
      cursor <- cursor - heading_height
    }
    for (line in lines[[i]]) {
      draw(line, cursor, body_gp)
      cursor <- cursor - line_height
    }
    cursor <- cursor - paragraph_gap
  }
  invisible(path)
}
