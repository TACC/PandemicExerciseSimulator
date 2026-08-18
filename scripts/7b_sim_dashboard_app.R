#////////
#### Script Overview ####
#////////
# Browser dashboard for exploring simulation metadata, checking run completion,
# and exporting finished scenarios to CSV.
#
# Run with:  shiny::runApp("scripts/sim_dashboard")
# Or open app.R in RStudio and click "Run App"
#
# Dependencies: shiny, bslib, DT, dplyr, readr, duckdb, arrow, bsicons
#////////
#### Load packages #############################################################
library(shiny)
library(plotly)
library(bslib)
library(DT)
library(tidyverse)
library(duckdb)
library(bsicons)

# ── Paths (relative to repo root) ────────────────────────────────────────────
DASHBOARD_DATA_DIR <- "STATE_WKLYFIT_TEST"
PROJECT_ROOT <- if (basename(getwd()) == "scripts") {
  normalizePath("..", mustWork = TRUE)
} else {
  normalizePath(getwd(), mustWork = TRUE)
}
DATA_ROOT    <- normalizePath(file.path(PROJECT_ROOT, DASHBOARD_DATA_DIR), mustWork = FALSE)
MASTER_CSV   <- file.path(DATA_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(DATA_ROOT, "sim_data")
message("Dashboard data root: ", DATA_ROOT)
message("Dashboard master rows: ", if (file.exists(MASTER_CSV)) nrow(readr::read_csv(MASTER_CSV, show_col_types = FALSE)) else 0)
AGE_LABELS   <- c("0-4", "5-17", "18-49", "50-64", "65+")
AGE_CHOICES  <- c("All ages" = "all", stats::setNames(as.character(seq_along(AGE_LABELS) - 1L), AGE_LABELS))

# ── Helpers ───────────────────────────────────────────────────────────────────

load_metadata <- function() {
  if (!file.exists(MASTER_CSV)) {
    return(tibble(
      scenario_hash = character(), batch_num = character(),
      metadata_creator = character(), metadata_disease = character(),
      metadata_sim_day_0 = character(), metadata_notes = character(),
      metadata_tags_json = character(), validation_used = logical(),
      validation_json = character(), validation_fit_data_file = character(),
      geo_region = character(), disease_identity = character(),
      vaccine_used = logical(), antiviral_used = logical(),
      npi_used = logical(), attempt_realization_count = integer(),
      complete_realization_count = integer(), mean_run_time_seconds = double(),
      created_at_utc = character()
    ))
  }
  metadata <- read_csv(
    MASTER_CSV,
    col_types = readr::cols(
      validation_json = readr::col_character(),
      validation_fit_data_file = readr::col_character(),
      .default = readr::col_guess()
    ),
    show_col_types = FALSE
  )
  optional_tag_columns <- c(
    "metadata_creator",
    "metadata_disease",
    "metadata_sim_day_0",
    "metadata_notes",
    "metadata_tags_json",
    "validation_json",
    "validation_fit_data_file"
  )
  for (column in optional_tag_columns) {
    if (!column %in% names(metadata)) metadata[[column]] <- NA_character_
  }
  if (!"validation_used" %in% names(metadata)) metadata[["validation_used"]] <- FALSE

  metadata %>%
    mutate(
      created_at_utc = as.POSIXct(created_at_utc, tz = "UTC"),
      validation_used = tidyr::replace_na(.data$validation_used, FALSE),
      validation_fit_data_file = dplyr::if_else(
        is.na(.data$validation_fit_data_file) | !nzchar(.data$validation_fit_data_file),
        infer_validation_fit_data_file(.data$geo_region, .data$metadata_sim_day_0),
        .data$validation_fit_data_file
      ),
      validation_used = .data$validation_used |
        (!is.na(.data$validation_fit_data_file) & nzchar(.data$validation_fit_data_file)),
      complete_pct   = round(100 * complete_realization_count /
                               pmax(attempt_realization_count, 1)),
      has_parquet    = file.exists(file.path(PARQUET_ROOT, scenario_hash,
                                             batch_num, "network.parquet"))
    )
}

parse_validation_json <- function(validation_json) {
  if (length(validation_json) == 0 || is.na(validation_json) || !nzchar(validation_json)) {
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(validation_json, simplifyVector = TRUE),
    error = function(e) NULL
  )
}

infer_validation_fit_data_file <- function(geo_region, sim_day_0) {
  candidate <- file.path(
    DATA_ROOT,
    "validation_fit_data",
    paste0("validation_fit_inc_hosp_", geo_region, "_", as.character(sim_day_0), ".csv")
  )
  dplyr::if_else(file.exists(candidate), candidate, NA_character_)
}

mmwr_week_end_date <- function(date) {
  date <- as.Date(date)
  date + ((6L - as.POSIXlt(date)$wday) %% 7L)
}

first_complete_mmwr_week_end <- function(sim_start_date) {
  sim_start_date <- as.Date(sim_start_date)
  first_sunday <- sim_start_date + ((7L - as.POSIXlt(sim_start_date)$wday) %% 7L)
  first_sunday + 6L
}

age_group_label <- function(age_group) {
  if (is.null(age_group) || length(age_group) == 0 || identical(age_group, "all")) {
    return("all")
  }
  age_group <- as.character(age_group[[1]])
  if (age_group %in% AGE_LABELS) {
    return(age_group)
  }
  age_index <- suppressWarnings(as.integer(age_group))
  if (!is.na(age_index) && age_index >= 0 && age_index < length(AGE_LABELS)) {
    return(AGE_LABELS[age_index + 1L])
  }
  NA_character_
}

age_group_index <- function(age_group) {
  label <- age_group_label(age_group)
  if (identical(label, "all") || is.na(label)) return(label)
  as.character(match(label, AGE_LABELS) - 1L)
}

split_metadata_tags <- function(x) {
  tags <- unlist(strsplit(paste(na.omit(x), collapse = "|"), "\\|"))
  tags <- trimws(tags)
  sort(unique(tags[nzchar(tags)]))
}

has_any_metadata_tag <- function(x, selected_tags) {
  vapply(
    x,
    function(value) length(intersect(split_metadata_tags(value), selected_tags)) > 0,
    logical(1)
  )
}

intervention_label <- function(vaccine_used, antiviral_used, npi_used) {
  dplyr::case_when(
    vaccine_used & antiviral_used & npi_used ~ "Vaccine + Antiviral + NPI",
    vaccine_used & antiviral_used            ~ "Vaccine + Antiviral",
    vaccine_used & npi_used                  ~ "Vaccine + NPI",
    antiviral_used & npi_used                ~ "Antiviral + NPI",
    vaccine_used                             ~ "Vaccine",
    antiviral_used                           ~ "Antiviral",
    npi_used                                 ~ "NPI",
    TRUE                                     ~ "Baseline"
  )
}

INTERVENTION_LEVELS <- c(
  "Baseline",
  "Antiviral",
  "NPI",
  "Vaccine",
  "Vaccine + Antiviral + NPI",
  "Antiviral + NPI",
  "Vaccine + NPI",
  "Vaccine + Antiviral"
)

INTERVENTION_COLORS <- c(
  "Baseline" = "#4D4D4D",
  "Antiviral" = "#F28E2B",
  "NPI" = "#59A14F",
  "Vaccine" = "#4E79A7",
  "Vaccine + Antiviral + NPI" = "#B07AA1",
  "Antiviral + NPI" = "#9C755F",
  "Vaccine + NPI" = "#76B7B2",
  "Vaccine + Antiviral" = "#EDC948"
)

intervention_order <- function(interventions) {
  order_index <- match(interventions, INTERVENTION_LEVELS)
  ifelse(is.na(order_index), length(INTERVENTION_LEVELS) + 1L, order_index)
}

resolve_validation_fit_data_file <- function(scenario_row, validation) {
  metadata_path <- scenario_row$validation_fit_data_file[[1]] %||% NA_character_
  if (!is.na(metadata_path) && nzchar(metadata_path) && file.exists(metadata_path)) {
    return(metadata_path)
  }
  if (!is.na(metadata_path) && nzchar(metadata_path)) {
    candidate <- if (grepl("^/", metadata_path)) metadata_path else file.path(DATA_ROOT, metadata_path)
    if (file.exists(candidate)) return(candidate)
  }

  tag_path <- validation$fit_data_file %||% NA_character_
  if (!is.na(tag_path) && nzchar(tag_path)) {
    candidate <- if (grepl("^/", tag_path)) tag_path else file.path(DATA_ROOT, tag_path)
    if (file.exists(candidate)) return(candidate)
  }

  NA_character_
}

validation_observed <- function(fit_data_file, age_group = "all") {
  if (is.na(fit_data_file) || !nzchar(fit_data_file) || !file.exists(fit_data_file)) return(NULL)
  
  selected_age_label <- age_group_label(age_group)
  if (is.na(selected_age_label)) return(NULL)

  observed <- readr::read_csv(fit_data_file, show_col_types = FALSE) %>%
    dplyr::mutate(
      date = as.Date(.data$date),
      age_group = as.character(.data$age_group),
      incident_hospitalizations = as.numeric(.data$incident_hospitalizations)
    )

  if (nrow(observed) == 0) return(NULL)
  
  if (!identical(selected_age_label, "all")) {
    observed <- observed %>%
      dplyr::filter(.data$age_group == selected_age_label)
    if (nrow(observed) == 0) return(NULL)
  }

  observed %>%
    dplyr::group_by(.data$date) %>%
    dplyr::summarise(
      observed = sum(.data$incident_hospitalizations, na.rm = TRUE),
      .groups = "drop"
    )
}

age_compartment_columns <- function(df, compartment, age_group) {
  column_names <- if (is.character(df)) df else names(df)
  if (identical(age_group, "all")) {
    if (compartment %in% column_names) return(compartment)
    pattern <- paste0("^", compartment, "_[HL]_[UV]_age[0-9]+$")
    return(grep(pattern, column_names, value = TRUE))
  }
  selected_age_index <- age_group_index(age_group)
  if (is.na(selected_age_index)) return(character(0))
  pattern <- paste0("^", compartment, "_[HL]_[UV]_age", selected_age_index, "$")
  grep(pattern, column_names, value = TRUE)
}

validation_generated <- function(scenario_hash, sim_start_date, age_group = "all") {
  column_names <- parquet_schema_names(scenario_hash, "nodes")
  if (is.null(column_names)) return(NULL)

  h_columns <- age_compartment_columns(column_names, "H", age_group)
  if (length(h_columns) == 0) return(NULL)

  parquet_files <- scenario_parquet_files(scenario_hash, "nodes")
  if (length(parquet_files) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  h_expr <- paste0(
    "COALESCE(",
    as.character(DBI::dbQuoteIdentifier(con, h_columns)),
    ", 0)"
  ) %>%
    paste(collapse = " + ")

  query <- paste0(
    "SELECT batch_num, sim_id, day, SUM(", h_expr, ") AS H_value ",
    "FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
    "GROUP BY batch_num, sim_id, day ",
    "ORDER BY batch_num, sim_id, day"
  )

  df <- DBI::dbGetQuery(con, query)
  if (nrow(df) == 0) return(NULL)

  df %>%
    dplyr::arrange(.data$batch_num, .data$sim_id, .data$day) %>%
    dplyr::group_by(.data$batch_num, .data$sim_id) %>%
    dplyr::mutate(
      incident_hospitalizations = pmax(.data$H_value - dplyr::lag(.data$H_value, default = dplyr::first(.data$H_value)), 0),
      calendar_date = as.Date(sim_start_date) + .data$day,
      date = mmwr_week_end_date(.data$calendar_date)
    ) %>%
    dplyr::group_by(.data$date, .data$batch_num, .data$sim_id) %>%
    dplyr::summarise(
      incident_hospitalizations = sum(.data$incident_hospitalizations, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::group_by(.data$date) %>%
    dplyr::summarise(
      generated_median = stats::median(.data$incident_hospitalizations, na.rm = TRUE),
      generated_lo = stats::quantile(.data$incident_hospitalizations, 0.05, na.rm = TRUE),
      generated_hi = stats::quantile(.data$incident_hospitalizations, 0.95, na.rm = TRUE),
      .groups = "drop"
    )
}

parquet_query <- function(batch_num, type = c("network", "nodes")) {
  type      <- match.arg(type)
  parquet   <- Sys.glob(file.path(PARQUET_ROOT, "*", batch_num,
                                  paste0(type, ".parquet")))
  if (length(parquet) == 0) return(NULL)
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", parquet[[1]]))
}

scenario_parquet_files <- function(scenario_hash, type = c("network", "nodes")) {
  type <- match.arg(type)
  Sys.glob(
    file.path(PARQUET_ROOT, scenario_hash, "*", paste0(type, ".parquet"))
  )
}

parquet_file_array_sql <- function(con, parquet_files) {
  paste0(
    "[",
    paste(DBI::dbQuoteString(con, parquet_files), collapse = ", "),
    "]"
  )
}

parquet_schema_names <- function(scenario_hash, type = c("network", "nodes")) {
  type <- match.arg(type)
  parquet_files <- scenario_parquet_files(scenario_hash, type)
  if (length(parquet_files) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  names(DBI::dbGetQuery(
    con,
    paste0(
      "SELECT * FROM read_parquet(",
      parquet_file_array_sql(con, parquet_files),
      ") LIMIT 0"
    )
  ))
}

parquet_query_scenario <- function(scenario_hash, type = c("network", "nodes"), columns = NULL) {
  type <- match.arg(type)
  parquet_files <- scenario_parquet_files(scenario_hash, type)
  if (length(parquet_files) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  select_sql <- if (is.null(columns)) {
    "*"
  } else {
    paste(as.character(DBI::dbQuoteIdentifier(con, unique(columns))), collapse = ", ")
  }

  query <- paste0(
    "SELECT ", select_sql, " FROM read_parquet(",
    parquet_file_array_sql(con, parquet_files),
    ")"
  )

  DBI::dbGetQuery(con, query)
}

scenario_compartment_timeseries <- function(scenario_hash, type = c("network", "nodes"), comp_columns) {
  type <- match.arg(type)
  parquet_files <- scenario_parquet_files(scenario_hash, type)
  if (length(parquet_files) == 0 || length(comp_columns) == 0) return(NULL)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  value_expr <- paste0(
    "COALESCE(",
    as.character(DBI::dbQuoteIdentifier(con, comp_columns)),
    ", 0)"
  ) %>%
    paste(collapse = " + ")

  if (identical(type, "nodes")) {
    query <- paste0(
      "SELECT batch_num, sim_id, day, SUM(", value_expr, ") AS value ",
      "FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
      "GROUP BY batch_num, sim_id, day ",
      "ORDER BY batch_num, sim_id, day"
    )
  } else {
    query <- paste0(
      "SELECT batch_num, sim_id, day, (", value_expr, ") AS value ",
      "FROM read_parquet(", parquet_file_array_sql(con, parquet_files), ") ",
      "ORDER BY batch_num, sim_id, day"
    )
  }

  DBI::dbGetQuery(con, query)
}

export_batch <- function(batch_num, tmp_dir) {
  source(file.path(PROJECT_ROOT, "scripts", "7_process_output_to_db.R"),
         local = new.env())
  # Call the export function defined in the ETL script
  env <- new.env()
  env$PARQUET_ROOT <- PARQUET_ROOT
  source(file.path(PROJECT_ROOT, "scripts", "7_process_output_to_db.R"),
         local = env)
  env$export_batch_csv(batch_num, tmp_dir)
}

# ── UI ────────────────────────────────────────────────────────────────────────

ui <- page_navbar(
  title = "Pandemic Sim Explorer",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  tags$head(
    tags$style(HTML("
      .scenario-table-card .card-body {
        padding-top: 0.5rem;
      }

      .scenario-table-toolbar {
        align-items: center;
        display: flex;
        flex-wrap: wrap;
        gap: 0.5rem 0.75rem;
        justify-content: space-between;
        margin-bottom: 0.35rem;
      }

      .scenario-table-toolbar .dt-buttons,
      .scenario-table-toolbar .dataTables_filter {
        float: none;
        margin: 0;
      }

      .scenario-table-toolbar .dataTables_filter label {
        align-items: center;
        display: flex;
        gap: 0.45rem;
        margin: 0;
      }

      .scenario-table-toolbar .dataTables_filter input {
        margin-left: 0;
        min-width: 18rem;
      }

      .scenario-table-info {
        font-size: 0.8rem;
        padding-top: 0.3rem;
      }

      .scenario-table-card table.dataTable {
        margin-top: 0 !important;
      }

      @media (max-width: 768px) {
        .scenario-table-toolbar {
          align-items: stretch;
        }

        .scenario-table-toolbar .dataTables_filter,
        .scenario-table-toolbar .dataTables_filter label,
        .scenario-table-toolbar .dataTables_filter input {
          width: 100%;
        }

        .scenario-table-toolbar .dataTables_filter input {
          min-width: 0;
        }
      }
    "))
  ),

  # ── Scenarios tab ──────────────────────────────────────────────────────────
  nav_panel(
    "Scenarios",
    icon = bs_icon("table"),

    page_sidebar(
      sidebar = sidebar(
        width = 280,
        accordion(
          open = TRUE,

          accordion_panel(
            "Geography & Model",
            icon = bs_icon("geo-alt"),
            selectizeInput("filter_region", "Region",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All regions")),
            selectizeInput("filter_disease", "Disease model",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All models")),
            selectizeInput("filter_metadata_disease", "Disease tag",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All disease tags")),
            selectizeInput("filter_metadata_creator", "Creator",
                           choices = NULL, multiple = TRUE,
                           options = list(placeholder = "All creators"))
          ),

          accordion_panel(
            "Interventions",
            icon = bs_icon("capsule"),
            input_switch("filter_vaccine",    "Vaccination",        FALSE),
            input_switch("filter_antiviral",  "Antivirals",         FALSE),
            input_switch("filter_npi",        "Non-pharmaceutical", FALSE),
            input_switch("filter_complete",   "All simulations complete", FALSE)
          ),

          accordion_panel(
            "File Creation Date range",
            icon = bs_icon("calendar3"),
            dateRangeInput("filter_dates", NULL,
                           start = Sys.Date() - 90, end = Sys.Date() + 1)
          )
        ),

        hr(),
        actionButton("refresh_btn", "Refresh data",
                     icon = icon("rotate"), class = "btn-outline-secondary w-100"),
        hr(),

        # Export panel — appears when rows are selected
        conditionalPanel(
          condition = "output.has_selection",
          div(
            class = "d-grid gap-2",
            downloadButton("export_meta_btn",  "Export metadata CSV",
                           class = "btn-outline-primary"),
            downloadButton("export_sims_btn",  "Export simulation CSVs",
                           class = "btn-outline-primary"),
            helpText("Simulation export requires Parquet files to exist.",
                     style = "font-size:0.75rem; color:#6c757d")
          )
        )
      ),

      # ── Summary row ─────────────────────────────────────────────────────────
      layout_column_wrap(
        width = "200px", fill = FALSE,
        value_box("Batches shown",       textOutput("n_batches_shown"),
                  theme = "primary",     showcase = bs_icon("stack")),
        value_box("Regions",             textOutput("n_regions_shown"),
                  theme = "info",        showcase = bs_icon("geo-alt")),
        value_box("Total realizations",  textOutput("n_real_shown"),
                  theme = "success",     showcase = bs_icon("activity")),
        value_box("With Parquet",        textOutput("n_parquet_shown"),
                  theme = "secondary",   showcase = bs_icon("database"))
      ),

      # ── Batch table ──────────────────────────────────────────────────────────
      card(
        class = "scenario-table-card",
        full_screen = TRUE,
        card_header(
          "Simulation batches",
          tooltip(bs_icon("info-circle", title = "Table info"),
                  "Click rows to select and enable data export. Filter to limit network time series previews in \"Network preview\" tab.")
        ),
        DTOutput("batch_table"),
        card_footer(
          "Completion = complete / attempted realizations.  ",
          "🟢 Parquet available   🔴 Parquet missing"
        )
      )
    )
  ),

  # ── Preview tab ─────────────────────────────────────────────────────────────
  nav_panel(
    "Network preview",
    icon = bs_icon("graph-up"),
    page_sidebar(
      sidebar = sidebar(
        width = 250,
        selectizeInput(
          "preview_scenario",
          "Scenario",
          choices = NULL,
          multiple = FALSE,
          options = list(placeholder = "Choose one scenario")
        ),
        selectInput("preview_compartment", "Compartment",
                    choices = NULL),
        selectInput("preview_age_group", "Age group",
                    choices = AGE_CHOICES,
                    selected = "all"),
        helpText("Shows network-level time series across all realizations.")
      ),
      card(
        full_screen = TRUE,
        card_header("Network time series"),
        plotly::plotlyOutput("network_plot", height = "450px")
        #plotOutput("network_plot", height = "450px")
      )
    )
  ),

  # ── Validation tab ─────────────────────────────────────────────────────────
  nav_panel(
    "Validation",
    icon = bs_icon("clipboard2-pulse"),
    page_sidebar(
      sidebar = sidebar(
        width = 280,
        selectizeInput(
          "validation_region",
          "Region",
          choices = NULL,
          multiple = FALSE,
          options = list(placeholder = "Choose one region")
        ),
        selectizeInput(
          "validation_sim_day_0",
          "Simulation day 0",
          choices = NULL,
          multiple = FALSE,
          options = list(placeholder = "Choose one date")
        ),
        selectizeInput(
          "validation_scenarios",
          "Scenarios",
          choices = NULL,
          multiple = TRUE,
          options = list(placeholder = "Choose scenarios to compare")
        ),
        selectInput("validation_age_group", "Age group",
                    choices = AGE_CHOICES,
                    selected = "all"),
        helpText("Choose one region and simulation start date, then select scenarios to compare.")
      ),
      card(
        full_screen = TRUE,
        card_header("Incident hospitalizations"),
        plotly::plotlyOutput("validation_plot", height = "450px")
      ),
      card(
        card_header("Validation data"),
        DTOutput("validation_table")
      )
    )
  ),

  # ── About tab ────────────────────────────────────────────────────────────────
  nav_panel(
    "About",
    icon = bs_icon("info-circle"),
    card(
      card_header("Data paths"),
      verbatimTextOutput("paths_info")
    ),
    card(
      card_header("Export instructions"),
      markdown("
**To ingest new simulation output:**
```r
source('scripts/7_process_output_to_db.R')
```

**To export a specific batch to CSV from R:**
```r
source('scripts/7_process_output_to_db.R')
export_batch_csv('<batch_num>', 'path/to/output/')
```

**Dashboard sub-population column naming convention:**

Node files contain stratified compartments in the form `{compartment}_{risk}_{vax}_{age}`:
- **risk**: H = high-risk, L = low-risk
- **vax**:  U = unvaccinated, V = vaccinated
- **age**:  age0 = 0–4, age1 = 5–17, age2 = 18–49, age3 = 50–64, age4 = 65+

Example: `IS_H_U_age4` = symptomatic infectious, high-risk, unvaccinated, 65+
      ")
    )
  )
)

# ── Server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  # Reactive metadata (re-loads on refresh)
  meta <- reactiveVal(load_metadata())

  observeEvent(input$refresh_btn, {
    meta(load_metadata())
    showNotification("Data refreshed.", type = "message", duration = 2)
  })

  # Populate filter dropdowns from data
  observe({
    df_all <- meta()
    
    updateSelectizeInput(
      session, "filter_region",
      choices = sort(unique(df_all$geo_region)),
      selected = isolate(input$filter_region),
      server = TRUE
    )
    
    updateSelectizeInput(
      session, "filter_disease",
      choices = sort(unique(df_all$disease_identity)),
      selected = isolate(input$filter_disease),
      server = TRUE
    )

    updateSelectizeInput(
      session, "filter_metadata_disease",
      choices = split_metadata_tags(df_all$metadata_disease),
      selected = isolate(input$filter_metadata_disease),
      server = TRUE
    )

    updateSelectizeInput(
      session, "filter_metadata_creator",
      choices = sort(unique(na.omit(df_all$metadata_creator))),
      selected = isolate(input$filter_metadata_creator),
      server = TRUE
    )
  })
  
  observe({
    df <- filtered()
    
    preview_df <- df %>%
      dplyr::filter(has_parquet) %>%
      dplyr::arrange(dplyr::desc(created_at_utc)) %>%
      dplyr::group_by(scenario_hash) %>%
      dplyr::slice(1) %>%
      dplyr::ungroup() %>%
      dplyr::mutate(
        scenario_label = paste(
          geo_region,
          disease_identity,
          substr(scenario_hash, nchar(scenario_hash) - 3, nchar(scenario_hash)),
          sep = " | "
        )
      )
    
    if (nrow(preview_df) == 0) {
      updateSelectizeInput(
        session,
        "preview_scenario",
        choices = character(0),
        selected = character(0),
        server = TRUE
      )
      return()
    }
    
    choices <- stats::setNames(preview_df$scenario_hash, preview_df$scenario_label)
    
    selected_now <- intersect(isolate(input$preview_scenario), preview_df$scenario_hash)
    if (length(selected_now) == 0) {
      selected_now <- preview_df$scenario_hash[[1]]
    } else {
      selected_now <- selected_now[[1]]
    }
    
    updateSelectizeInput(
      session,
      "preview_scenario",
      choices = choices,
      selected = selected_now,
      server = TRUE
    )
  })

  observe({
    validation_regions <- filtered() %>%
      dplyr::filter(.data$has_parquet, .data$validation_used) %>%
      dplyr::pull(.data$geo_region) %>%
      unique() %>%
      sort()

    selected_now <- intersect(isolate(input$validation_region), validation_regions)
    if (length(selected_now) == 0 && length(validation_regions) > 0) {
      selected_now <- validation_regions[[1]]
    }

    updateSelectizeInput(
      session,
      "validation_region",
      choices = validation_regions,
      selected = selected_now,
      server = TRUE
    )
  })

  observe({
    req(input$validation_region)

    validation_dates <- filtered() %>%
      dplyr::filter(
        .data$has_parquet,
        .data$validation_used,
        .data$geo_region == input$validation_region
      ) %>%
      dplyr::mutate(metadata_sim_day_0 = as.character(.data$metadata_sim_day_0)) %>%
      dplyr::pull(.data$metadata_sim_day_0) %>%
      unique() %>%
      sort()

    selected_now <- intersect(isolate(input$validation_sim_day_0), validation_dates)
    if (length(selected_now) == 0 && length(validation_dates) > 0) {
      selected_now <- validation_dates[[1]]
    }

    updateSelectizeInput(
      session,
      "validation_sim_day_0",
      choices = validation_dates,
      selected = selected_now,
      server = TRUE
    )
  })

  observe({
    req(input$validation_region, input$validation_sim_day_0)

    validation_df <- filtered() %>%
      dplyr::filter(
        .data$has_parquet,
        .data$validation_used,
        .data$geo_region == input$validation_region,
        as.character(.data$metadata_sim_day_0) == input$validation_sim_day_0
      ) %>%
      dplyr::arrange(dplyr::desc(.data$created_at_utc)) %>%
      dplyr::group_by(.data$scenario_hash) %>%
      dplyr::slice(1) %>%
      dplyr::ungroup() %>%
      dplyr::mutate(
        interventions = intervention_label(.data$vaccine_used, .data$antiviral_used, .data$npi_used),
        intervention_order = intervention_order(.data$interventions),
        scenario_label = paste(
          .data$interventions,
          paste0("hash ", substr(.data$scenario_hash, nchar(.data$scenario_hash) - 3, nchar(.data$scenario_hash))),
          sep = " | "
        )
      ) %>%
      dplyr::arrange(.data$intervention_order, .data$scenario_label)

    if (nrow(validation_df) == 0) {
      updateSelectizeInput(
        session,
        "validation_scenarios",
        choices = character(0),
        selected = character(0),
        server = TRUE
      )
      return()
    }

    choices <- stats::setNames(validation_df$scenario_hash, validation_df$scenario_label)
    selected_now <- intersect(isolate(input$validation_scenarios), validation_df$scenario_hash)

    if (length(selected_now) == 0) {
      baseline_hashes <- validation_df %>%
        dplyr::filter(.data$interventions == "Baseline") %>%
        dplyr::pull(.data$scenario_hash)
      selected_now <- c(
        baseline_hashes,
        setdiff(validation_df$scenario_hash, baseline_hashes)
      )
    }

    updateSelectizeInput(
      session,
      "validation_scenarios",
      choices = choices,
      selected = selected_now,
      server = TRUE
    )
  })
  
  # Update compartment choices when batch changes
  observeEvent(input$preview_scenario, {
    if (length(input$preview_scenario) == 0 || is.null(input$preview_scenario)) {
      updateSelectInput(session, "preview_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }
    
    column_names <- parquet_schema_names(input$preview_scenario, "network")
    
    if (is.null(column_names)) {
      updateSelectInput(session, "preview_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }
    
    excluded_cols <- c("scenario_hash", "batch_num", "sim_id", "day")
    compartment_choices <- setdiff(column_names, excluded_cols)
    
    preferred_order <- c("S", "E", "A", "IA", "IP", "IS", "I", "T", "H", "R", "D")
    ordered_choices <- c(
      intersect(preferred_order, compartment_choices),
      setdiff(compartment_choices, preferred_order)
    )
    
    if (length(ordered_choices) == 0) {
      updateSelectInput(session, "preview_compartment",
                        choices = character(0),
                        selected = character(0))
      return()
    }
    
    default_choice <- if ("IS" %in% ordered_choices) {
      "IS"
    } else if ("I" %in% ordered_choices) {
      "I"
    } else {
      ordered_choices[[1]]
    }
    
    updateSelectInput(
      session,
      "preview_compartment",
      choices = ordered_choices,
      selected = default_choice
    )
  })

  # Filtered data
  filtered <- reactive({
    df <- meta()
    if (length(input$filter_region)  > 0) df <- dplyr::filter(df, geo_region       %in% input$filter_region)
    if (length(input$filter_disease) > 0) df <- dplyr::filter(df, disease_identity  %in% input$filter_disease)
    if (length(input$filter_metadata_disease) > 0) {
      df <- dplyr::filter(df, has_any_metadata_tag(.data$metadata_disease, input$filter_metadata_disease))
    }
    if (length(input$filter_metadata_creator) > 0) {
      df <- dplyr::filter(df, metadata_creator %in% input$filter_metadata_creator)
    }
    if (isTRUE(input$filter_vaccine))    df <- dplyr::filter(df, vaccine_used)
    if (isTRUE(input$filter_antiviral))  df <- dplyr::filter(df, antiviral_used)
    if (isTRUE(input$filter_npi))        df <- dplyr::filter(df, npi_used)
    if (isTRUE(input$filter_complete))   df <- dplyr::filter(df, complete_pct == 100)
    df <- dplyr::filter(df,
                 created_at_utc >= as.POSIXct(input$filter_dates[[1]]),
                 created_at_utc <= as.POSIXct(input$filter_dates[[2]]) + 86400)
    df
  })
  
  # Link selected table row to network preview
  observeEvent(input$batch_table_rows_selected, {
    idx <- input$batch_table_rows_selected
    
    # Only sync preview when exactly one row is selected
    if (length(idx) != 1) return()
    
    selected_hash <- filtered()$scenario_hash[idx]
    
    updateSelectizeInput(
      session,
      "preview_scenario",
      selected = selected_hash
    )
    updateSelectizeInput(
      session,
      "validation_region",
      selected = filtered()$geo_region[idx]
    )
    updateSelectizeInput(
      session,
      "validation_sim_day_0",
      selected = as.character(filtered()$metadata_sim_day_0[idx])
    )
    updateSelectizeInput(
      session,
      "validation_scenarios",
      selected = selected_hash
    )
  })

  # Summary value boxes
  output$n_batches_shown  <- renderText(nrow(filtered()))
  output$n_regions_shown  <- renderText(n_distinct(filtered()$geo_region))
  output$n_real_shown     <- renderText(
    format(sum(filtered()$complete_realization_count, na.rm = TRUE), big.mark = ","))
  output$n_parquet_shown  <- renderText(sum(filtered()$has_parquet, na.rm = TRUE))

  # Batch table
  output$batch_table <- renderDT({
    df <- filtered() %>%
      mutate(
        scenario_hash_4 = substr(.data$scenario_hash, nchar(.data$scenario_hash) - 3, nchar(.data$scenario_hash)),
        parquet = if_else(has_parquet, "🟢", "🔴"),
        completion = sprintf("%d%%  (%d / %d)",
                             replace_na(complete_pct, 0),
                             replace_na(complete_realization_count, 0L),
                             replace_na(attempt_realization_count, 0L)),
        interventions = intervention_label(vaccine_used, antiviral_used, npi_used),
        created = format(created_at_utc, "%Y-%m-%d %H:%M")
      ) %>%
      mutate(metadata_disease = stringr::str_replace_all(.data$metadata_disease, "\\|", ", ")) %>%
      select(scenario_hash_4, parquet, geo_region, metadata_creator, metadata_disease,
             metadata_sim_day_0, metadata_notes,
             disease_identity, disease_R0, sim_days,
             interventions, completion, mean_run_time_seconds, created, 
             batch_num, scenario_hash, total_parquet_file_size)

    datatable(
      df,
      rownames   = FALSE,
      selection  = "multiple",
      filter     = "top",
      extensions = "Buttons",
      options    = list(
        paging = FALSE,
        scrollY = "calc(100vh - 365px)",
        scrollCollapse = FALSE,
        scrollX = TRUE,
        deferRender = TRUE,
        dom = "<'scenario-table-toolbar'Bf>t",
        buttons = list(
          list(extend = "colvis", text = "Columns")
        ),
        columnDefs = list(
          list(visible = FALSE, targets = c(1, 3, 4, 6, 14, 15)),
          list(className = "dt-center", targets = c(0, 1))
        )
      ),
      colnames = c("Hash", "File Exists", "Region", "Creator", "Disease Tags",
                   "Simulation Day 0", "Notes", "Model", "R0", "Run Day Max",
                   "Interventions",
                   "Sim Completion", "Mean Run Time (sec)", "Created",
                   "batch_num", "scenario_hash", "Total Parquet Size")
    ) %>%
      formatRound("mean_run_time_seconds", digits = 2)
  })

  # Tell the UI whether any rows are selected (for conditional export panel)
  output$has_selection <- reactive({
    length(input$batch_table_rows_selected) > 0
  })
  outputOptions(output, "has_selection", suspendWhenHidden = FALSE)

  # Selected batch_nums
  selected_rows <- reactive({
    idx <- input$batch_table_rows_selected
    if (length(idx) == 0) return(character(0))
    filtered()$batch_num[idx]
  })

  # ── Export metadata CSV ────────────────────────────────────────────────────
  output$export_meta_btn <- downloadHandler(
    filename = function() {
      sprintf("metadata_export_%s.csv", format(Sys.time(), "%Y-%m-%d"))
    },
    content = function(file) {
      filtered() %>%
        dplyr::filter(batch_num %in% selected_rows()) %>%
        select(-has_parquet, -complete_pct) %>%
        write_csv(file)
    }
  )

  # ── Export simulation CSVs (zipped) ──────────────────────────────────────
  output$export_sims_btn <- downloadHandler(
    filename = function() {
      sprintf("sim_export_%s.zip", format(Sys.time(), "%Y-%m-%d"))
    },
    content = function(file) {
      message("START export_sims_btn")
      tmp <- tempfile()
      dir.create(tmp)
      on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
      
      bns <- selected_rows()
      message("Selected batch nums: ", paste(bns, collapse = ", "))
      if (length(bns) == 0) {
        stop("No rows selected for export.")
      }

      withProgress(message = "Exporting simulations…", {
        for (i in seq_along(bns)) {
          bn      <- bns[[i]]
          out_dir <- file.path(tmp, bn)
          dir.create(out_dir)
          
          message("Exporting batch: ", bn)

          # Write network CSV
          net_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "network.parquet"))
          if (length(net_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
            res <- dbGetQuery(
              con,
              sprintf("SELECT * 
                       FROM read_parquet('%s') 
                       ORDER BY sim_id, day",
                      net_pq[[1]])
            )
            write_csv(res, file.path(out_dir, paste0("network_batch-", bn, ".csv")))
          }

          # Write nodes CSV
          node_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "nodes.parquet"))
          if (length(node_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
            res <- dbGetQuery(
              con, # EXCLUDE (scenario_hash, batch_num) 
              sprintf("SELECT * 
                       FROM read_parquet('%s') 
                       ORDER BY fips_id, sim_id, day",
                      node_pq[[1]])
            )
            write_csv(res, file.path(out_dir, paste0("nodes_batch-", bn, ".csv")))
          }
          
          # Write simulation times CSV
          times_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "simulation_times.parquet"))
          if (length(times_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
            res <- dbGetQuery(
              con,
              sprintf(
                "SELECT * 
                 FROM read_parquet('%s')
                 ORDER BY sim_id",
                times_pq[[1]]
              )
            )
            write_csv(res, file.path(out_dir, paste0("simulation_times_batch-", bn, ".csv")))
          }

          incProgress(1 / length(bns), detail = bn)
        } # end for i
      })

      # Zip everything
      files_to_zip <- list.files(tmp, full.names = TRUE, recursive = TRUE)
      if (length(files_to_zip) == 0) {
        stop("No CSV files were created for export.")
      }
      utils::zip(file, files = files_to_zip,
          flags = "-j")
    }
  )

  selected_validation <- reactive({
    validate(need(length(input$validation_region) > 0,
                  "Choose a region for validation comparison."))
    validate(need(length(input$validation_sim_day_0) > 0,
                  "Choose a simulation start date for validation comparison."))
    validate(need(length(input$validation_scenarios) > 0,
                  "Choose one or more scenarios to compare."))

    scenario_rows <- meta() %>%
      dplyr::filter(
        .data$scenario_hash %in% input$validation_scenarios,
        .data$geo_region == input$validation_region,
        as.character(.data$metadata_sim_day_0) == input$validation_sim_day_0,
        .data$has_parquet,
        .data$validation_used
      ) %>%
      dplyr::arrange(dplyr::desc(created_at_utc)) %>%
      dplyr::group_by(.data$scenario_hash) %>%
      dplyr::slice(1) %>%
      dplyr::ungroup() %>%
      dplyr::mutate(
        validation_sim_start_date = as.Date(purrr::map2_chr(
          .data$validation_json,
          .data$metadata_sim_day_0,
          function(validation_json, metadata_sim_day_0) {
            validation_i <- parse_validation_json(validation_json)
            if (is.null(validation_i)) {
              return(as.character(metadata_sim_day_0))
            }
            as.character(validation_i$sim_start_date %||% metadata_sim_day_0)
          }
        )),
        comparison_start_date = first_complete_mmwr_week_end(.data$validation_sim_start_date),
        interventions = intervention_label(.data$vaccine_used, .data$antiviral_used, .data$npi_used),
        intervention_order = intervention_order(.data$interventions),
        scenario_label = paste0(
          .data$interventions,
          " (",
          substr(.data$scenario_hash, nchar(.data$scenario_hash) - 3, nchar(.data$scenario_hash)),
          ")"
        )
      ) %>%
      dplyr::arrange(.data$intervention_order, .data$scenario_label)

    validate(need(nrow(scenario_rows) > 0, "No validation metadata found for the selected scenarios."))

    validation <- parse_validation_json(scenario_rows$validation_json[[1]])
    if (is.null(validation)) {
      validation <- list(sim_start_date = as.character(scenario_rows$metadata_sim_day_0[[1]]))
    }
    
    fit_data_file <- resolve_validation_fit_data_file(scenario_rows[1, ], validation)
    validate(need(!is.na(fit_data_file),
                  "No validation fit data file is available for this scenario."))

    age_group <- input$validation_age_group %||% "all"
    observed <- validation_observed(fit_data_file, age_group)
    validate(need(!is.null(observed), "No observed validation records are available."))
    comparison_start_date <- max(scenario_rows$comparison_start_date, na.rm = TRUE)
    observed <- observed %>%
      dplyr::filter(.data$date >= comparison_start_date)
    validate(need(nrow(observed) > 0,
                  "No observed validation records remain after dropping partial leading model weeks."))

    generated <- purrr::map_dfr(
      seq_len(nrow(scenario_rows)),
      function(row_index) {
        row <- scenario_rows[row_index, ]
        sim_start_date <- row$validation_sim_start_date[[1]]
        generated_i <- validation_generated(row$scenario_hash[[1]], sim_start_date, age_group)
        if (is.null(generated_i)) return(tibble::tibble())
        generated_i %>%
          dplyr::mutate(
            scenario_hash = row$scenario_hash[[1]],
            scenario_label = row$scenario_label[[1]],
            interventions = row$interventions[[1]],
            intervention_order = row$intervention_order[[1]]
          )
      }
    )
    generated <- generated %>%
      dplyr::filter(.data$date >= comparison_start_date)
    validate(need(nrow(generated) > 0,
                  "No generated hospitalization series is available for the selected scenarios."))

    list(
      rows = scenario_rows,
      validation = validation,
      fit_data_file = fit_data_file,
      age_group = age_group,
      age_group_label = age_group_label(age_group),
      comparison_start_date = comparison_start_date,
      observed = observed,
      generated = generated
    )
  })

  output$validation_plot <- plotly::renderPlotly({
    v <- selected_validation()

    observed_plot_df <- v$observed %>%
      dplyr::filter(!is.na(.data$observed))

    generated_plot_df <- v$generated %>%
      dplyr::filter(
        !is.na(.data$generated_lo),
        !is.na(.data$generated_hi),
        !is.na(.data$generated_median)
      )

    title_text <- as.character(paste0(
      input$validation_region,
      " | ",
      input$validation_sim_day_0,
      " | ",
      if (identical(v$age_group_label, "all")) "all ages" else v$age_group_label,
      " | observed fit target vs generated incident hospitalizations"
    ))

    scenario_levels <- v$rows %>%
      dplyr::filter(.data$scenario_label %in% unique(generated_plot_df$scenario_label)) %>%
      dplyr::arrange(.data$intervention_order, .data$scenario_label) %>%
      dplyr::pull(.data$scenario_label) %>%
      as.character()
    scenario_interventions <- v$rows$interventions[match(scenario_levels, v$rows$scenario_label)]
    scenario_colors <- INTERVENTION_COLORS[scenario_interventions]
    names(scenario_colors) <- scenario_levels

    validation_plot <- plotly::plot_ly()
    for (scenario in scenario_levels) {
      ribbon_df <- generated_plot_df %>%
        dplyr::filter(.data$scenario_label == scenario)
      validation_plot <- validation_plot %>%
        plotly::add_ribbons(
          data = ribbon_df,
          x = ~date,
          ymin = ~generated_lo,
          ymax = ~generated_hi,
          name = as.character(paste0(scenario, " 5th-95th percentile")),
          legendgroup = as.character(scenario),
          showlegend = FALSE,
          fillcolor = grDevices::adjustcolor(scenario_colors[[scenario]], alpha.f = 0.16),
          line = list(color = "rgba(0,0,0,0)"),
          hoverinfo = "skip"
        )
    }

    for (scenario in scenario_levels) {
      line_df <- generated_plot_df %>%
        dplyr::filter(.data$scenario_label == scenario)
      validation_plot <- validation_plot %>%
        plotly::add_lines(
          data = line_df,
          x = ~date,
          y = ~generated_median,
          name = as.character(scenario),
          legendgroup = as.character(scenario),
          line = list(color = scenario_colors[[scenario]], width = 2.5)
        )
    }

    validation_plot %>%
      plotly::add_markers(
        data = observed_plot_df,
        x = ~date,
        y = ~observed,
        name = "Observed fitted data",
        marker = list(color = "rgb(225,87,89)", size = 8)
      ) %>%
      plotly::layout(
        title = list(text = title_text),
        xaxis = list(title = list(text = "Week ending date")),
        yaxis = list(title = list(text = "Incident hospitalizations")),
        hovermode = "x unified"
      )
  })

  output$validation_table <- renderDT({
    v <- selected_validation()

    dplyr::full_join(v$observed, v$generated, by = "date") %>%
      dplyr::arrange(.data$date) %>%
      dplyr::select(
        "date",
        "scenario_label",
        "observed",
        "generated_median",
        "generated_lo",
        "generated_hi"
      ) %>%
      dplyr::mutate(dplyr::across(where(is.numeric), ~ round(.x, 2))) %>%
      DT::datatable(
        rownames = FALSE,
        extensions = c("FixedHeader"),
        options = list(
          paging = FALSE,
          scrollY = "420px",
          scrollCollapse = TRUE,
          scrollX = TRUE,
          fixedHeader = TRUE,
          order = list(list(0, "asc")),
          dom = "t"
        )
      )
  })

  # ── Network preview plot ───────────────────────────────────────────────────
  output$network_plot <- plotly::renderPlotly({
    validate(need(length(input$preview_scenario) > 0,
                  "No scenario available for the current table filter."))
    validate(need(length(input$preview_compartment) > 0,
                  "No compartment available for the selected scenario."))
    
    preview_age_group <- input$preview_age_group %||% "all"
    preview_data_type <- if (identical(preview_age_group, "all")) "network" else "nodes"

    comp <- input$preview_compartment
    column_names <- parquet_schema_names(input$preview_scenario, preview_data_type)
    validate(need(!is.null(column_names), paste("No", preview_data_type, "parquet found for this scenario.")))

    comp_columns <- age_compartment_columns(column_names, comp, preview_age_group)
    validate(need(length(comp_columns) > 0 && all(comp_columns %in% column_names),
                  paste("Column not found in", preview_data_type, "data for:", comp)))

    df <- scenario_compartment_timeseries(input$preview_scenario, preview_data_type, comp_columns)
    validate(need(!is.null(df), paste("No", preview_data_type, "parquet found for this scenario.")))
    
    meta_df <- meta() %>%
      dplyr::filter(scenario_hash == input$preview_scenario) %>%
      dplyr::mutate(
        interventions = intervention_label(vaccine_used, antiviral_used, npi_used)
      ) %>%
      dplyr::select(
        batch_num,
        sim_days,
        geo_region,
        disease_R0,
        interventions
      )
    
    # get last 4 digits of hash for labeling
    df_plot <- df %>%
      dplyr::left_join(meta_df, by = "batch_num") %>%
      dplyr::mutate(
        batch_label = paste0(
          "batch ",
          substr(batch_num, nchar(batch_num) - 3, nchar(batch_num)),
          " | ",
          sim_days,
          " days"
        ),
        line_id = as.character(paste(batch_num, sim_id, sep = "_")),
        hover_text = paste0(
          "Batch: ", batch_label,
          "<br>Sim: ", sim_id,
          "<br>Day: ", day,
          "<br>Value: ", value
        )
      ) %>%
      dplyr::arrange(batch_num, sim_id, day)
    
    # Plot with one line per simulation, with descriptive title
    total_sims <- dplyr::n_distinct(df_plot$line_id)
    
    geo_region <- unique(meta_df$geo_region)[1]
    r0_value   <- unique(meta_df$disease_R0)[1]
    
    intervention_text <- meta_df %>%
      dplyr::pull(interventions) %>%
      unique() %>%
      sort() %>%
      paste(collapse = ", ")
    
    age_text <- if (identical(preview_age_group, "all")) {
      "all ages"
    } else {
      age_group_label(preview_age_group)
    }
    
    title_text <- as.character(paste0(
      geo_region, " | ",
      age_text, " | ",
      intervention_text, " | ",
      "R0=", round(r0_value, 2), " | ",
      total_sims, " sims"
    ))
    
    plotly::plot_ly(
      data = df_plot,
      x = ~day,
      y = ~value,
      type = "scatter",
      mode = "lines",
      split = ~line_id,
      line = list(color = "rgba(78,121,167,0.6)", width = 1.5),
      text = ~hover_text,
      hovertemplate = "%{text}<extra></extra>"
    ) %>%
      plotly::layout(
        title = list(text = paste0(title_text, "<br>")),
        xaxis = list(title = list(text = "Day")),
        yaxis = list(title = list(text = as.character(comp))),
        showlegend = FALSE
      )
  })

  # ── About tab ──────────────────────────────────────────────────────────────
  output$paths_info <- renderText({
    sprintf(
      "MASTER_CSV   : %s\nPARQUET_ROOT : %s\n\nMaster CSV exists : %s\nParquet root exists : %s",
      MASTER_CSV, PARQUET_ROOT,
      file.exists(MASTER_CSV),
      dir.exists(PARQUET_ROOT)
    )
  })
}

shinyApp(ui, server)
