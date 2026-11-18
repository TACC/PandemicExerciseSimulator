# Run from the repository root: Rscript --vanilla test/test_manuscript_fit_shape.R
# Shape screening must distinguish matched peaks from matched epidemic curves.
suppressPackageStartupMessages(library(tidyverse))
env <- new.env(parent=globalenv())
for (step in parse('scripts/10a_manuscript_state_fit_figures.R')) {
  if (is.call(step) && identical(step[[1]],as.name('<-')) &&
      (identical(step[[2]],as.name('FIT_SCREENING')) ||
       (is.call(step[[3]]) && identical(step[[3]][[1]],as.name('function'))))) eval(step,env)
}
time <- -20:30
dates <- as.Date('2025-12-27') + time*7
narrow <- 100*exp(-.5*(time/2)^2)
long_fall <- 100*exp(-.5*(time/ifelse(time<0,2,7))^2)
long_rise <- 100*exp(-.5*(time/ifelse(time<0,7,2))^2)
classify_fixture <- function(observed,fitted,calendar=dates) {
  env$weekly <- tibble(date=dates)
  env$classify(tibble(date=calendar, observed=observed, q0_5=fitted,
    mean_generated=fitted, q0_025=pmax(0,fitted-10), q0_975=fitted+10))
}
perfect <- classify_fixture(narrow,narrow)
stopifnot(perfect$category=='single_peak_good', perfect$nrmse_peak==0,
          abs(perfect$observed_asymmetry20)<1e-10)
# Scale changes cannot change normalized errors or shape classifications.
scale_a <- classify_fixture(narrow,narrow*.95)
scale_b <- classify_fixture(narrow*1000,narrow*.95*1000)
stopifnot(all.equal(scale_a$nrmse_peak,scale_b$nrmse_peak),
          all.equal(scale_a$rise20_error_weeks,scale_b$rise20_error_weeks),
          scale_a$category==scale_b$category)
# Same peak height and week cannot conceal a prolonged observed decline/rise.
fall <- classify_fixture(long_fall,narrow)
rise <- classify_fixture(long_rise,narrow)
stopifnot(fall$prolonged_decline_missed, rise$prolonged_rise_missed,
          fall$fit_quality=='bad', rise$fit_quality=='bad',
          fall$observed_asymmetry20>0, rise$observed_asymmetry20<0,
          fall$review_reason=='Observed decline longer than fitted decline')
# An asymmetric curve is acceptable when its shape is actually reproduced.
asymmetric <- classify_fixture(long_fall,long_fall)
stopifnot(asymmetric$fit_quality=='good',asymmetric$observed_asymmetry20>.4,
          abs(asymmetric$asymmetry20_error)<1e-10)
# A second large wave is never eligible as a clean single peak.
two <- narrow+90*exp(-.5*((time-13)/2)^2)
multiple <- classify_fixture(two,narrow)
stopifnot(multiple$n_significant_peaks==2L, multiple$category!='single_peak_good')
# Small-amplitude sustained tails are diagnosed separately from the core.
low_tail <- narrow
low_tail[time>=7 & time<=25] <- 8
low <- classify_fixture(low_tail,narrow)
stopifnot(low$low_tail_underestimated,low$fit_quality=='good',
          grepl('low-level tail underestimated',low$review_reason,fixed=TRUE))
# Observation truncation and missing dates stay visible, rather than silently
# treating a clipped rise as complete or replacing gaps with zero incidence.
clipped <- classify_fixture(tail(narrow,32),tail(narrow,32),tail(dates,32))
stopifnot(clipped$shape_window_censored,clipped$incomplete_observation_window,
          clipped$fit_quality=='bad')
keep <- seq_along(dates)!=10L
gap <- classify_fixture(narrow[keep],narrow[keep],dates[keep])
stopifnot(gap$incomplete_observation_window,gap$nrmse_peak==0)
# Calendar widths use elapsed time even with gaps.
pw <- env$peak_width(c(0,100,0),as.Date('2025-01-01')+c(0,7,28),.5)
stopifnot(pw$rise==.5,pw$decline==1.5)
cat('Manuscript shape screening tests passed\n')
