# Rscript --vanilla test/test_dashboard_map_async.R
# A slow map request must leave this same Shiny session able to update another
# output. Also check latest-selection wins, cache reuse, and a separate worker.
app <- new.env(parent = globalenv())
expressions <- parse("scripts/7b_sim_dashboard_app.R")
for (expression in expressions[-length(expressions)]) eval(expression, app)
worker_query <- function(path, sim_id, value_columns) {
  Sys.sleep(1.5)
  data.frame(value = as.integer(path), pid = Sys.getpid())
}
environment(worker_query) <- baseenv()
parent_pid <- Sys.getpid()
test_server <- function(input, output, session) {
  request <- shiny::reactive({
    shiny::req(input$key)
    list(key = input$key, path = input$path, sim_id = "0", columns = "x")
  })
  loader <- app$county_map_background_loader(request, cachem::cache_mem(max_size = 1024^2), worker_query)
  other_seen <- shiny::reactiveVal(NULL)
  shiny::observe({
    other_seen(list(value = input$other, map_status = shiny::isolate(loader$task$status())))
  })
  output$other_tab <- shiny::renderText(paste("Responsive:", input$other))
}
wait_for <- function(predicate, session, timeout = 12) {
  end <- Sys.time() + timeout
  while (!predicate()) {
    if (Sys.time() > end) stop("Async map test timed out")
    later::run_now(0.05)
    session$flushReact()
    session$elapse(250)
  }
}
shiny::testServer(test_server, {
  session$setInputs(key = "first:ABC::0", path = "1", other = "A")
  session$elapse(250)
  stopifnot(loader$task$status() == "running")
  session$setInputs(other = "B")
  stopifnot(other_seen()$value == "B", other_seen()$map_status == "running")
  # Change selection while work is already running; do not enqueue each click.
  session$setInputs(key = "second", path = "2")
  session$elapse(250)
  session$setInputs(key = "latest", path = "3")
  session$elapse(250)
  wait_for(function() identical(loader$value()$key, "latest"), session)
  stopifnot(loader$value()$data$value == 3L, loader$value()$data$pid != parent_pid)
  # The first finished result was cached even though its selection became stale.
  session$setInputs(key = "first:ABC::0", path = "1")
  session$elapse(250)
  stopifnot(loader$value()$key == "first:ABC::0", loader$value()$data$value == 1L,
            loader$task$status() != "running")
  stopifnot(output$other_tab == "Responsive: B")
})
future::plan(future::sequential)
cat("Async map: same-session responsiveness, latest-selection wins, cache reuse and separate worker passed.\n")
