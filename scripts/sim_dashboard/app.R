# sim_dashboard/app.R
#
# Browser dashboard for exploring simulation metadata, checking run completion,
# and exporting finished scenarios to CSV.
#
# Run with:  shiny::runApp("scripts/sim_dashboard")
# Or open app.R in RStudio and click "Run App"
#
# Dependencies: shiny, bslib, DT, dplyr, readr, duckdb, arrow, bsicons

#### Load packages #############################################################
library(shiny)
library(plotly)
library(bslib)
library(DT)
library(tidyverse)
library(duckdb)
library(bsicons)

# ── Paths (relative to repo root) ────────────────────────────────────────────

REPO_ROOT    <- normalizePath(file.path(here::here(), ".."))
MASTER_CSV   <- file.path(REPO_ROOT, "metadata_master.csv")
PARQUET_ROOT <- file.path(REPO_ROOT, "sim_data")

# ── Helpers ───────────────────────────────────────────────────────────────────

load_metadata <- function() {
  if (!file.exists(MASTER_CSV)) {
    return(tibble(
      scenario_hash = character(), batch_num = character(),
      geo_region = character(), disease_identity = character(),
      vaccine_used = logical(), antiviral_used = logical(),
      npi_used = logical(), attempt_realization_count = integer(),
      complete_realization_count = integer(), mean_run_time_seconds = double(),
      created_at_utc = character()
    ))
  }
  read_csv(MASTER_CSV, show_col_types = FALSE) %>%
    mutate(
      created_at_utc = as.POSIXct(created_at_utc, tz = "UTC"),
      complete_pct   = round(100 * complete_realization_count /
                               pmax(attempt_realization_count, 1)),
      has_parquet    = file.exists(file.path(PARQUET_ROOT, scenario_hash,
                                             batch_num, "network.parquet"))
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

parquet_query_scenario <- function(scenario_hash, type = c("network", "nodes")) {
  type <- match.arg(type)
  
  parquet_files <- Sys.glob(
    file.path(PARQUET_ROOT, scenario_hash, "*", paste0(type, ".parquet"))
  )
  
  if (length(parquet_files) == 0) return(NULL)
  
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  
  file_array_sql <- paste0(
    "[",
    paste(DBI::dbQuoteString(con, parquet_files), collapse = ", "),
    "]"
  )
  
  query <- paste0(
    "SELECT * FROM read_parquet(",
    file_array_sql,
    ")"
  )
  
  DBI::dbGetQuery(con, query)
}

export_batch <- function(batch_num, tmp_dir) {
  source(file.path(REPO_ROOT, "scripts", "7_process_output_to_db.R"),
         local = new.env())
  # Call the export function defined in the ETL script
  env <- new.env()
  env$PARQUET_ROOT <- PARQUET_ROOT
  source(file.path(REPO_ROOT, "scripts", "7_process_output_to_db.R"),
         local = env)
  env$export_batch_csv(batch_num, tmp_dir)
}

# ── UI ────────────────────────────────────────────────────────────────────────

ui <- page_navbar(
  title = "Pandemic Sim Explorer",
  theme = bs_theme(version = 5, bootswatch = "flatly"),

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
                           options = list(placeholder = "All models"))
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
                           class = "btn-primary"),
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
        full_screen = TRUE,
        card_header(
          "Simulation batches",
          tooltip(bs_icon("info-circle", title = "Table info"),
                  "Select rows to enable export. Click a row to preview the network time series below.")
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
        selectInput("preview_scenario", "Scenario", choices = NULL),
        selectInput("preview_compartment", "Compartment",
                    choices = NULL),
        helpText("Shows aggregate network-level time series across all realizations.")
      ),
      card(
        full_screen = TRUE,
        card_header("Network time series"),
        #plotly::plotlyOutput("network_plot", height = "450px")
        plotOutput("network_plot", height = "450px")
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
    df <- meta()
    
    updateSelectizeInput(session, "filter_region",
                         choices  = sort(unique(df$geo_region)),
                         selected = character(0), server = TRUE)
    
    updateSelectizeInput(session, "filter_disease",
                         choices  = sort(unique(df$disease_identity)),
                         selected = character(0), server = TRUE)
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
    
    choices <- setNames(preview_df$scenario_hash, preview_df$scenario_label)
    
    updateSelectizeInput(
      session,
      "preview_scenario",
      choices = choices,
      selected = preview_df$scenario_hash[[1]],
      server = TRUE
    )
  })
  
  # Update compartment choices when batch changes
  observeEvent(input$preview_scenario, {
    req(input$preview_scenario)
    
    df <- parquet_query_scenario(input$preview_scenario, "network")
    
    if (is.null(df)) {
      updateSelectInput(session, "preview_compartment", choices = character(0))
      return()
    }
    
    excluded_cols <- c("scenario_hash", "batch_num", "sim_id", "day")
    compartment_choices <- setdiff(names(df), excluded_cols)
    
    preferred_order <- c("S", "E", "A", "IA", "IP", "IS", "I", "T", "H", "R", "D")
    ordered_choices <- c(
      intersect(preferred_order, compartment_choices),
      setdiff(compartment_choices, preferred_order)
    )
    
    default_choice <- if ("IS" %in% ordered_choices) {
      "IS"
    } else if ("I" %in% ordered_choices) {
      "I"
    } else if (length(ordered_choices) > 0) {
      ordered_choices[[1]]
    } else {
      character(0)
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
    if (isTRUE(input$filter_vaccine))    df <- dplyr::filter(df, vaccine_used)
    if (isTRUE(input$filter_antiviral))  df <- dplyr::filter(df, antiviral_used)
    if (isTRUE(input$filter_npi))        df <- dplyr::filter(df, npi_used)
    if (isTRUE(input$filter_complete))   df <- dplyr::filter(df, complete_pct == 100)
    df <- dplyr::filter(df,
                 created_at_utc >= as.POSIXct(input$filter_dates[[1]]),
                 created_at_utc <= as.POSIXct(input$filter_dates[[2]]) + 86400)
    df
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
        parquet = if_else(has_parquet, "🟢", "🔴"),
        completion = sprintf("%d%%  (%d / %d)",
                             replace_na(complete_pct, 0),
                             replace_na(complete_realization_count, 0L),
                             replace_na(attempt_realization_count, 0L)),
        interventions = case_when(
          vaccine_used & npi_used  ~ "Vaccine + NPI",
          vaccine_used             ~ "Vaccine",
          antiviral_used           ~ "Antiviral",
          npi_used                 ~ "NPI",
          TRUE                     ~ "Baseline"
        ),
        created = format(created_at_utc, "%Y-%m-%d %H:%M")
      ) %>%
      select(parquet, geo_region, disease_identity, interventions,
             completion, mean_run_time_seconds, created, batch_num, scenario_hash)

    datatable(
      df,
      rownames   = FALSE,
      selection  = "multiple",
      filter     = "top",
      extensions = "Buttons",
      options    = list(
        pageLength = 25,
        dom        = "Bfrtip",
        buttons    = list("colvis"),
        columnDefs = list(
          list(visible = FALSE, targets = c(7, 8)),  # hide batch/hash cols
          list(className = "dt-center", targets = 0)
        )
      ),
      colnames = c("", "Region", "Model", "Interventions",
                   "Completion", "Mean run (s)", "Created", "batch_num", "scenario_hash")
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
      sprintf("metadata_export_%s.csv", format(Sys.time(), "%Y%m%d_%H%M%S"))
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
      sprintf("sim_export_%s.zip", format(Sys.time(), "%Y%m%d_%H%M%S"))
    },
    content = function(file) {
      tmp <- tempfile()
      dir.create(tmp)
      on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

      withProgress(message = "Exporting simulations…", {
        bns <- selected_rows()
        for (i in seq_along(bns)) {
          bn      <- bns[[i]]
          out_dir <- file.path(tmp, bn)
          dir.create(out_dir)

          # Write network CSV
          net_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "network.parquet"))
          if (length(net_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            res <- dbGetQuery(
              con,
              sprintf("SELECT * EXCLUDE (scenario_hash, batch_num) FROM read_parquet('%s') ORDER BY sim_id, day",
                      net_pq[[1]])
            )
            dbDisconnect(con, shutdown = TRUE)
            write_csv(res, file.path(out_dir, paste0("network_batch-", bn, ".csv")))
          }

          # Write nodes CSV
          node_pq <- Sys.glob(file.path(PARQUET_ROOT, "*", bn, "nodes.parquet"))
          if (length(node_pq) > 0) {
            con <- dbConnect(duckdb(), dbdir = ":memory:")
            res <- dbGetQuery(
              con,
              sprintf("SELECT * EXCLUDE (scenario_hash, batch_num) FROM read_parquet('%s') ORDER BY fips_id, sim_id, day",
                      node_pq[[1]])
            )
            dbDisconnect(con, shutdown = TRUE)
            write_csv(res, file.path(out_dir, paste0("nodes_batch-", bn, ".csv")))
          }

          incProgress(1 / length(bns), detail = bn)
        }
      })

      # Zip everything
      zip(file, files = list.files(tmp, full.names = TRUE, recursive = TRUE),
          flags = "-j")
    }
  )

  # ── Network preview plot ───────────────────────────────────────────────────
  #output$network_plot <- plotly::renderPlotly({
  output$network_plot <- renderPlot({
    req(input$preview_scenario, input$preview_compartment)
    
    df <- parquet_query_scenario(input$preview_scenario, "network")
    validate(need(!is.null(df), "No network parquet found for this scenario."))
    
    comp <- input$preview_compartment
    validate(need(comp %in% names(df),
                  paste("Column not found in network data:", comp)))
    
    meta_df <- meta() |>
      dplyr::filter(scenario_hash == input$preview_scenario) |>
      dplyr::select(batch_num, sim_days)
    
    df_plot <- df |>
      dplyr::group_by(batch_num, sim_id, day) |>
      dplyr::summarise(value = sum(.data[[comp]], na.rm = TRUE), .groups = "drop") |>
      dplyr::left_join(meta_df, by = "batch_num") |>
      dplyr::mutate(
        batch_label = paste0(
          "batch ",
          substr(batch_num, nchar(batch_num) - 3, nchar(batch_num)),
          " | ",
          sim_days,
          " days"
        )
      )
    
    p <- ggplot2::ggplot(
      df_plot,
      ggplot2::aes(
        x = day,
        y = value,
        group = interaction(batch_num, sim_id),
        color = batch_label,
        text = paste0(
          "Batch: ", substr(batch_num, nchar(batch_num) - 3, nchar(batch_num)),
          "<br>Days: ", sim_days,
          "<br>Sim: ", sim_id,
          "<br>Day: ", day,
          "<br>Value: ", value
        )
      )
    ) +
      ggplot2::geom_line(alpha = 0.5, linewidth = 0.6) +
      ggplot2::labs(
        title = comp,
        x = "Day",
        y = comp,
        color = "Batch"
      ) +
      ggplot2::theme_minimal(base_size = 13)
    
    #plotly::ggplotly(p, tooltip = "text")
    p
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
