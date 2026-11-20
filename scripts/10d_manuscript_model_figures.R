#!/usr/bin/env Rscript
# Draw the disease model and parameter comparison without running simulations.
script <- sub("^--file=", "", commandArgs()[startsWith(commandArgs(), "--file=")][1])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "scripts/manuscript_figure_legends.R"))

args <- commandArgs(trailingOnly = TRUE)
figure_arg <- args[startsWith(args, "--figure-dir=")]
figure_dir <- if (length(figure_arg)) sub("^--figure-dir=", "", figure_arg[[1]]) else
  file.path(repo, "figures/manuscript")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
seir_arg <- args[startsWith(args, "--seir-input-dir=")]
seir_input_dir <- if (length(seir_arg)) sub("^--seir-input-dir=", "", seir_arg[[1]]) else
  file.path(repo, "MANUSCRIPT_ILLUSTRATIVE_EXAMPLE_TEST", "inputs")

draw_model <- function() {
  nodes <- data.frame(
    id = c("S", "E", "IA", "IP", "IS", "H", "R", "D", "T"),
    label = c("Susceptible", "Exposed", "Asymptomatic\ninfectious", "Presymptomatic\ninfectious",
      "Symptomatic\ninfectious", "Hospitalized", "Recovered", "Deceased", "Antiviral treatment"),
    x = c(1.95, 2.80, 4.95, 4.15, 5.83, 7.73, 7.73, 7.73, 5.83),
    y = c(4.20, 1.10, 1.10, 2.56, 2.56, 2.34, 1.10, 3.60, 4.17),
    label_x = c(1.95, 2.80, 4.95, 4.15, 5.83, 8.63, 7.73, 8.63, 5.83),
    label_y = c(4.66, .65, .58, 3.08, 2.03, 2.34, .65, 3.60, 4.73),
    fill = c("#F3F3F3", "#9CA58D", rep("#777777", 3), "#E7C8BB", "#EEF0E7", "#B8B8B8", "#f2ad2e")
  )
  radius <- .30
  arrow_color <- "#555555"
  antiviral_color <- "#bd6b4f"
  callout_color <- "#825148"
  inches <- function(x) grid::unit(x, "inches")
  endpoints <- function(from, to) {
    from <- match(from, nodes$id)
    to <- match(to, nodes$id)
    dx <- nodes$x[to] - nodes$x[from]
    dy <- nodes$y[to] - nodes$y[from]
    inset <- (radius + .04) / sqrt(dx^2 + dy^2)
    data.frame(x = nodes$x[from] + inset * dx, y = nodes$y[from] + inset * dy,
      xend = nodes$x[to] - inset * dx, yend = nodes$y[to] - inset * dy)
  }
  segment <- function(x, y, xend, yend, color, linewidth = 1.6, tip = .09, lty = "solid") {
    arrow <- if (tip > 0) grid::arrow(type = "closed", length = inches(tip)) else NULL
    grid::segmentsGrob(inches(x), inches(y), inches(xend), inches(yend),
      arrow = arrow, gp = grid::gpar(col = color, fill = color, lwd = linewidth, lty = lty))
  }
  progression <- endpoints(
    c("S", "E", "E", "IA", "IP", "IS", "IS", "H", "H", "T"),
    c("E", "IA", "IP", "R", "IS", "H", "R", "R", "D", "H")
  )
  treated_recovery <- endpoints("T", "R")
  treatment <- endpoints("IS", "T")
  tip_base_y <- treatment$yend - .15
  infection <- endpoints("S", "E")
  infection_x <- function(height) {
    with(infection, x + (xend - x) * (height - y) / (yend - y)) - .06
  }
  grid::grobTree(
    with(progression, segment(x, y, xend, yend, arrow_color)),
    # A white gap at the crossing keeps the two transitions distinct.
    with(treated_recovery, segment(x, y, xend, yend, "white", linewidth = 5, tip = 0)),
    with(treated_recovery, segment(x, y, xend, yend, arrow_color)),
    with(treatment, segment(x, y, xend, tip_base_y, antiviral_color, 2, tip = 0, lty = "dashed")),
    with(treatment, segment(x, tip_base_y, xend, yend, antiviral_color, 2, tip = .12)),
    segment(1.42, 3.10, infection_x(3.10), 3.10, callout_color, 1.8),
    segment(1.72, 1.68, infection_x(2.46), 2.46, callout_color, 1.8),
    grid::roundrectGrob(inches(.90), inches(3.10), inches(1.00), inches(.44),
      r = inches(.06), gp = grid::gpar(fill = "#ECE8EF", col = "#95899A")),
    grid::roundrectGrob(inches(1.05), inches(1.68), inches(1.32), inches(.60),
      r = inches(.06), gp = grid::gpar(fill = "#F6ECE6", col = "#AC8172")),
    grid::textGrob(c("NPIs", "Vaccination\nagainst infection"), inches(c(.90, 1.05)), inches(c(3.10, 1.68)),
      gp = grid::gpar(fontsize = 10.5, fontface = "bold", col = "#333333")),
    grid::circleGrob(inches(nodes$x), inches(nodes$y), inches(radius),
      gp = grid::gpar(fill = nodes$fill, col = arrow_color, lwd = 1.35)),
    grid::textGrob(expression(bold(S), bold(E), bold(I[A]), bold(I[P]), bold(I[S]),
      bold(H), bold(R), bold(D), bold(T)), inches(nodes$x), inches(nodes$y),
      gp = grid::gpar(fontsize = 17, col = "black")),
    grid::textGrob(nodes$label, inches(nodes$label_x), inches(nodes$label_y),
      gp = grid::gpar(fontsize = 10.5, col = "#333333"))
  )
}

ggplot2::ggsave(file.path(figure_dir, "SEIHRD_compartmental_model.png"),
  draw_model(), width = 9.35, height = 5, dpi = 600, bg = "white")
write_manuscript_legend(figure_dir, "SEIHRD_compartmental_model",
  "Stochastic SEIHRD compartmental model", c(
    paste("Susceptible people enter E after infection. On leaving E, they enter the asymptomatic",
      "infectious state (IA) or the presymptomatic infectious state (IP). IP progresses to",
      "symptomatic infection (IS). IA recovers, whereas IS can recover or be hospitalized (H).",
      "Hospitalized people recover (R) or die (D)."),
    paste("The dashed arrow shows stockpile-dependent antiviral allocation from eligible",
      "symptomatic people (IS) to the optional treated compartment (T). Solid arrows show",
      "disease progression. Treated people can recover or be hospitalized."),
    paste("Nonpharmaceutical interventions (NPIs) reduce local transmission, and vaccination",
      "reduces susceptibility to infection. Both act on the S-to-E transition.",
      "The H3N2 configuration sets direct vaccine effectiveness against hospitalization to 0%."),
    paste("IA, IP, IS, and T contribute to infection pressure, weighted by relative infectiousness.",
      "The asymptomatic branch fraction varies by age. Hospitalization varies by age and risk",
      "group, and the in-hospital death fraction varies by age.")
  ))

read_config <- function(path) jsonlite::read_json(path, simplifyVector = TRUE)
template_dir <- file.path(repo, "data", "INPUT_FILE_TEMPLATES")
seihrd <- read_config(file.path(template_dir, "INPUT_SEIHRD-STOCH_STATE_NONE_H3N2.json"))$disease_model$parameters
state_interventions <- read_config(file.path(template_dir, "INPUT_SEIHRD-STOCH_STATE_ALL_INTERVENTIONS_H3N2.json"))
delaware_config <- function(scenario) {
  paths <- file.path(seir_input_dir,
    paste0("INPUT_", scenario, "_", c("deterministic", "stochastic"), "_Delaware.json"))
  if (!all(file.exists(paths))) {
    stop("Missing Delaware input JSONs in ", seir_input_dir,
      ". Generate them with scripts/10b_manuscript_illustrative_example.R --prepare-only.")
  }
  comparable_fields <- function(path) {
    config <- read_config(path)
    list(disease = config$disease_model$parameters, vaccine = config$vaccine_model$parameters,
      antiviral = config$antiviral_model$parameters, npi = config$non_pharma_interventions,
      travel = config$travel_model$parameters, initial_exposed = config$initial_exposed)
  }
  deterministic <- comparable_fields(paths[1])
  if (!identical(deterministic, comparable_fields(paths[2]))) {
    stop("Delaware parameters differ between model variants for scenario ", scenario)
  }
  deterministic
}
delaware_low <- delaware_config("low")
delaware_high <- delaware_config("high")
seir <- delaware_high$disease
delaware_seed_counts <- vapply(list(delaware_low, delaware_high), function(config) {
  sum(as.numeric(config$initial_exposed$infected))
}, numeric(1))
delaware_seeds <- paste(format(delaware_seed_counts, big.mark = ",", trim = TRUE, scientific = FALSE),
  collapse = " or ")
seed_strata <- unique(rbind(delaware_low$initial_exposed[c("county", "age_group")],
  delaware_high$initial_exposed[c("county", "age_group")]))
delaware_counties <- c("10001" = "Kent County", "10003" = "New Castle County", "10005" = "Sussex County")
delaware_ages <- c("0\u20134", "5\u201317", "18\u201349", "50\u201364", "65+")
seed_summary <- if (nrow(seed_strata) == 1L) {
  paste0(delaware_seeds, " (", delaware_ages[as.integer(seed_strata$age_group) + 1L],
    " yr)\n", delaware_counties[seed_strata$county])
} else {
  paste0(delaware_seeds, " people\nAcross county and age groups")
}
state_vaccine <- state_interventions$vaccine_model$parameters
state_antiviral <- state_interventions$antiviral_model$parameters
state_treated <- state_interventions$disease_model$parameters
state_npi <- state_interventions$non_pharma_interventions
delaware_vaccine <- delaware_config("vax100k")$vaccine
delaware_vaccine_high <- delaware_config("vax1m")$vaccine
delaware_antiviral <- delaware_config("antiviral10k")
delaware_antiviral_high <- delaware_config("antiviral100k")
delaware_npi <- delaware_config("closure")$npi
format_values <- function(value) {
  paste(format(as.numeric(value), trim = TRUE, drop0trailing = TRUE), collapse = ", ")
}
percent <- function(value) {
  paste(paste0(format(100 * as.numeric(value), trim = TRUE, drop0trailing = TRUE), "%"), collapse = ", ")
}
stockpile_totals <- function(low, high, compact = FALSE) {
  totals <- c(sum(as.numeric(low$amount)), sum(as.numeric(high$amount)))
  labels <- format(totals, big.mark = ",", trim = TRUE, scientific = FALSE)
  if (compact) {
    thousands <- totals >= 1000 & totals %% 1000 == 0
    millions <- totals >= 1000000 & totals %% 1000000 == 0
    labels[thousands] <- paste0(totals[thousands] / 1000, "K")
    labels[millions] <- paste0(totals[millions] / 1000000, "M")
  }
  paste(labels, collapse = " or ")
}
release_days <- function(stockpile) {
  days <- range(as.integer(stockpile$day))
  if (days[1] == days[2]) paste("day", days[1]) else paste0("days ", paste(days, collapse = "\u2013"))
}
npi_days <- as.integer(delaware_npi$day) + c(1L, as.integer(delaware_npi$duration))
delaware_vaccine_doses <- stockpile_totals(delaware_vaccine$vaccine_stockpile,
  delaware_vaccine_high$vaccine_stockpile, compact = TRUE)
delaware_antiviral_courses <- stockpile_totals(delaware_antiviral$antiviral$antiviral_stockpile,
  delaware_antiviral_high$antiviral$antiviral_stockpile)
rows <- rbind(
  c("Transmission and initialization", "", ""),
  c("Reproduction number", "Rm fit per state to weekly\nincident hospital admissions",
    paste("R0 =", format_values(seir$R0), "(fixed)")),
  c("Initial exposed (E0)\nLow risk only", "Fit to state peak week\nBy county and age", seed_summary),
  c("IP / IA infectiousness vs. IS",
    paste(format_values(seihrd$rel_inf_IP_to_IS), format_values(seihrd$rel_inf_IA_to_IS), sep = " / "), ""),
  c("Progression and recovery (days)", "", ""),
  c("Latent period (E)", format_values(seihrd$E_to_IPandIA_days), format_values(seir$E_to_I_days)),
  c("Symptom onset (IP to IS)", format_values(seihrd$IP_to_IS_days), ""),
  c("Asymptomatic to recovered", format_values(seihrd$IA_to_R_days), ""),
  c("Recovery from I or IS", format_values(seihrd$IS_to_R_days), format_values(seir$I_to_R_days)),
  c("Symptomatic to hospitalized", format_values(seihrd$IS_to_H_days), ""),
  c("Hospitalized to recovered", format_values(seihrd$H_to_R_days), ""),
  c("Hospitalized to deceased", format_values(seihrd$H_to_D_days), ""),
  c("Waning immunity (R to S)", "Disabled", if (as.numeric(seir$R_to_S_days) == 0) "Disabled" else seir$R_to_S_days),
  c("Branch fractions and risk", "", ""),
  c("Asymptomatic E exits (%)", format_values(100 * as.numeric(seihrd$prop_E_to_IA)), ""),
  c("Hospitalized (low-risk IS, %)", format_values(100 * as.numeric(seihrd$prop_IS_to_H_lowrisk)), ""),
  c("High-risk multiplier for H", paste0(format_values(seihrd$highrisk_hosp_multiplier), "x"), ""),
  c("Deaths among H (%)", format_values(100 * as.numeric(seihrd$prop_H_to_D)), ""),
  c("Vaccination", "", ""),
  c("Protection against infection", percent(unique(state_vaccine$vaccine_effectiveness)),
    percent(unique(delaware_vaccine$vaccine_effectiveness))),
  c("Direct protection against H",
    percent(unique(if (is.null(state_vaccine$vaccine_effectiveness_hosp)) 0 else state_vaccine$vaccine_effectiveness_hosp)), ""),
  c("Eligibility and adherence", paste("All ages/risks /", percent(unique(state_vaccine$vaccine_adherence))),
    paste("All ages/risks /", percent(unique(delaware_vaccine$vaccine_adherence)))),
  c("Dose supply and schedule", "Weekly doses by state",
    paste0(delaware_vaccine_doses, ", ", release_days(delaware_vaccine$vaccine_stockpile))),
  c("Protection lag (days)", format_values(state_vaccine$vaccine_eff_lag_days),
    format_values(delaware_vaccine$vaccine_eff_lag_days)),
  c("Antivirals", "", ""),
  c("Eligibility and allocation", paste("New high-risk IS, all ages\n", percent(unique(state_antiviral$antiviral_adherence)),
    " adherence", sep = ""), "Current I, all ages/risks\nWhile courses remain"),
  c("Supply and release timing", "Day 0: state insured\nhigh-risk population",
    paste0(delaware_antiviral_courses, " courses\non ",
      release_days(delaware_antiviral$antiviral$antiviral_stockpile))),
  c("T infectiousness vs. IS or I", format_values(state_treated$rel_inf_T_to_IS),
    format_values(delaware_antiviral$disease$rel_inf_T_to_I)),
  c("T to recovery input (days)", format_values(state_treated$T_to_R_days),
    format_values(delaware_antiviral$disease$T_to_R_days)),
  c("Hospitalization risk target", paste(percent(state_antiviral$antiviral_effectiveness_hosp), "reduction"), ""),
  c("T weights (travel / transmit)",
    paste(state_interventions$travel_model$parameters$traveling_compartments$T,
      state_interventions$travel_model$parameters$transmitting_compartments$T, sep = " / "),
    paste(delaware_antiviral$travel$traveling_compartments$T,
      delaware_antiviral$travel$transmitting_compartments$T, sep = " / ")),
  c("Capacity (vaccine / antiviral)",
    paste(percent(state_vaccine$vaccine_capacity_proportion),
      percent(state_antiviral$antiviral_capacity_proportion), sep = " / "),
    paste(percent(delaware_vaccine$vaccine_capacity_proportion),
      percent(delaware_antiviral$antiviral$antiviral_capacity_proportion), sep = " / ")),
  c("Nonpharmaceutical interventions (NPIs)", "", ""),
  c("Scenario and timing", "Weekend mobility decrease\nSaturdays and Sundays",
    paste0("School closure, days ", paste(npi_days, collapse = "\u2013"), "\nAdult contacts also reduced")),
  c("Local transmission reduction",
    percent(unique(unlist(state_npi$effectiveness))), percent(unlist(delaware_npi$effectiveness))),
  c("Geographic scope", "All counties in each state", "All three Delaware counties")
)

# Use a wider aspect ratio for portrait-page placement with a caption below.
table_width <- 7.5
column_x <- c(.025, .344, .658)
column_widths <- diff(c(column_x, .983)) * table_width - .09
body_gp <- grid::gpar(fontfamily = "Helvetica", fontsize = 12.6, lineheight = 1.16, col = "#1d2b34")

wrap_table_rows <- function(rows, section) {
  grDevices::pdf(NULL, width = table_width, family = "Helvetica")
  on.exit(grDevices::dev.off())
  wrap_cell <- function(cell, width) {
    wrap_line <- function(line) {
      words <- strsplit(line, " ", fixed = TRUE)[[1]]
      current <- words[1]
      lines <- character()
      for (word in words[-1]) {
        candidate <- paste(current, word)
        candidate_width <- grid::convertWidth(grid::grobWidth(grid::textGrob(candidate, gp = body_gp)),
          "inches", valueOnly = TRUE)
        if (candidate_width > width) {
          lines <- c(lines, current)
          current <- word
        } else {
          current <- candidate
        }
      }
      c(lines, current)
    }
    paste(unlist(lapply(strsplit(cell, "\n", fixed = TRUE)[[1]], wrap_line)), collapse = "\n")
  }
  for (column in seq_len(ncol(rows))) {
    rows[!section, column] <- vapply(rows[!section, column], wrap_cell,
      character(1), width = column_widths[column])
  }
  rows
}

section <- rows[, 2] == "" & rows[, 3] == ""
rows[!section & rows == ""] <- "\u2014"
rows <- wrap_table_rows(rows, section)
line_counts <- matrix(lengths(strsplit(as.vector(rows), "\n", fixed = TRUE)), nrow = nrow(rows))
row_heights <- .235 + .205 * (apply(line_counts, 1, max) - 1)
header_height <- .50
table_height <- sum(row_heights) + header_height + .12

draw_parameters <- function(rows) {
  top <- table_height - .06
  y <- top - header_height - cumsum(row_heights) + row_heights / 2
  inches <- function(x) grid::unit(x, "inches")
  column_labels <- c("Parameter", "Stochastic SEIHRD\nH3N2 state scenarios", "SEIR\nDelaware illustration")
  grid::grobTree(
    grid::rectGrob(.5, inches(top - header_height / 2), .982, inches(header_height),
      gp = grid::gpar(fill = "#153247", col = NA)),
    grid::textGrob(column_labels, column_x, inches(top - header_height / 2), just = "left",
      gp = grid::gpar(fontfamily = "Helvetica", fontsize = 13.5, lineheight = 1.12, col = "white", fontface = "bold")),
    grid::rectGrob(.5, inches(y), .982, inches(row_heights),
      gp = grid::gpar(fill = ifelse(section, "#e0ebf0", rep(c("#f7f9fa", "white"),
        length.out = nrow(rows))), col = NA)),
    grid::textGrob(rows[section, 1], column_x[1], inches(y[section]), just = "left",
      gp = grid::gpar(fontfamily = "Helvetica", fontsize = 13, col = "#153247", fontface = "bold")),
    grid::textGrob(rows[!section, 1], column_x[1], inches(y[!section]), just = "left", gp = body_gp),
    grid::textGrob(rows[!section, 2], column_x[2], inches(y[!section]), just = "left", gp = body_gp),
    grid::textGrob(rows[!section, 3], column_x[3], inches(y[!section]), just = "left", gp = body_gp)
  )
}

ggplot2::ggsave(file.path(figure_dir, "SEIHRD_SEIR_parameters.png"),
  draw_parameters(rows), width = table_width, height = table_height, dpi = 600, bg = "white")
write_manuscript_legend(figure_dir, "SEIHRD_SEIR_parameters", "SEIHRD and SEIR parameters", c(
  "Configurations" = paste("SEIHRD natural-history parameters come from the no-intervention H3N2 template.",
    "Intervention settings come from the H3N2",
    "all-interventions template and its state-specific scheduling rules. SEIR values come from",
    "the saved Delaware inputs shared by the deterministic and stochastic illustrations."),
  "Transmission and initial exposures" = paste("The SEIHRD state fits use observed weekly incident",
    "hospital admissions. Rm is calibrated to peak height, and the total number exposed on day 0",
    "(E0) is adjusted to align the peak week by scaling the hospitalization-derived county-by-age seeds.",
    "Final selection considers peak-height tolerance and peak-week error. The Delaware SEIR illustration",
    "uses a fixed R0 and compares two day-0 exposure counts. Initial exposures in both models",
    "are restricted to the low-risk group."),
  "Age and risk groups" = paste("Comma-separated values are in age order 0-4, 5-17, 18-49, 50-64,",
    "and 65+ years. The high-risk hospitalization target is the low-risk target times the",
    "listed multiplier. Dashes mark parameters that do not apply."),
  "Timing and branching" = paste("Transition-day inputs are inverted to obtain baseline daily",
    "rates. For competing paths out of IS and H, the simulator adjusts rate multipliers to",
    "target the configured branch fractions. With competing exits, mean residence time depends",
    "on the combined rates."),
  "Vaccination and antiviral schedules" = paste("The H3N2 pipeline replaces the template stockpile",
    "entries with state-specific weekly vaccine doses and a day-0 antiviral stockpile sized to the",
    "insured high-risk population. Delaware compares two supply levels for each pharmaceutical",
    "intervention. Vaccination applies to susceptible people. The daily capacity parameter is",
    "expressed as a fraction of county population. The saved settings have no stockpile decay."),
  "Nonpharmaceutical interventions" = paste("The weekend and school-closure schedules reduce",
    "local transmission by contacted age. The H3N2 weekend reduction is the same for all five age groups.")
))
