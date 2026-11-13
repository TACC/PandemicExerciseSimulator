#!/usr/bin/env Rscript
# Delaware input figure. Run from repository root or scripts/.
suppressPackageStartupMessages({library(ggplot2); library(sf); library(cowplot)})
args <- commandArgs(trailingOnly = TRUE)
arg <- function(key, default) { x <- args[startsWith(args, key)]; if(length(x)) substring(x[1], nchar(key)+1) else default }
script_flags <- commandArgs()[startsWith(commandArgs(),"--file=")]
root <- if (length(script_flags)) dirname(dirname(normalizePath(sub("^--file=","",script_flags[1])))) else
  normalizePath(if(basename(getwd()) == "scripts") ".." else ".")
out <- arg("--output-dir=", file.path(root,"MANUSCRIPT_ILLUSTRATIVE_EXAMPLE_TEST/input_figure"))
dir.create(out, recursive=TRUE, showWarnings=FALSE)
figure_dir <- arg("--figure-dir=",file.path(root,"figures/manuscript"))
dir.create(figure_dir,recursive=TRUE,showWarnings=FALSE)
data_dir <- arg("--data-dir=",file.path(root,"data/Delaware"))
pop <- read.csv(file.path(data_dir,"county_pop_by_age_Delaware_2020-2024ACS.csv"), check.names=FALSE)
risk <- read.csv(file.path(data_dir,"county_Delaware_high-risk-ratios-flu-only.csv"), check.names=FALSE)
ages <- names(pop)[-1]
stopifnot(!anyDuplicated(risk$fips), all(pop$fips %in% risk$fips))
risk <- risk[match(pop$fips,risk$fips),c("fips",ages)]
pop$total <- rowSums(pop[,ages]); pop$id <- seq_len(nrow(pop))
pop$county <- c("Kent","New Castle","Sussex")
contact <- as.matrix(read.csv(file.path(data_dir,"contact_matrix_Delaware_Mistry2021_all.csv"),header=FALSE))
flow <- as.matrix(read.csv(file.path(data_dir,"Delaware_Q4-2019_mobility-matrix.csv"),header=FALSE))
stopifnot(identical(dim(contact),c(5L,5L)), identical(dim(flow),c(3L,3L)))
bundled_shape <- file.path(data_dir,"Delaware_counties.gpkg")
shape_file <- arg("--county-shapefile=",if(file.exists(bundled_shape)) bundled_shape else
  path.expand("~/Library/Caches/tigris/cb_2023_us_county_500k.shp"))
if(!file.exists(shape_file)) stop("Supply cached Census county boundaries with --county-shapefile=")
shape <- st_read(shape_file,quiet=TRUE)
shape <- st_transform(shape[shape$GEOID %in% as.character(pop$fips),],5070)
shape <- shape[match(as.character(pop$fips),shape$GEOID),]
shape$total <- pop$total; shape$id <- pop$id
st_write(shape,file.path(out,"Delaware_counties.gpkg"),delete_dsn=TRUE,quiet=TRUE)
# ggplot geometry text sizes use mm; theme and cowplot text use points.
figure_width <- 12.5
figure_height <- 8.5
figure_dpi <- 600
main_pt <- 13
title_pt <- 17
main_mm <- main_pt / ggplot2::.pt
base_theme <- theme_minimal(base_size=main_pt) + theme(
  text=element_text(size=main_pt), panel.grid=element_blank(),
  axis.text=element_text(size=main_pt), axis.title=element_text(size=main_pt),
  plot.title=element_text(face="bold",size=title_pt),
  plot.subtitle=element_text(size=main_pt), legend.title=element_text(size=main_pt,hjust=.5),
  legend.text=element_text(size=main_pt), legend.position="right",
  legend.box="vertical",legend.title.position="top",
  legend.key.width=grid::unit(.18,"inches"),
  legend.key.height=grid::unit(.55,"inches"),
  legend.margin=margin(0,0,0,6),plot.margin=margin(6,8,6,6))
gray <- c("#F3F3F3","#777777")
A <- ggplot(shape)+geom_sf(aes(fill=total),color="white",linewidth=.7)+
  geom_sf_text(aes(label=id),size=main_mm,fontface="bold")+
  scale_fill_gradient(low=gray[1],high=gray[2],name="Population",breaks=c(200000,500000),labels=scales::label_number(scale=1e-3,suffix="K"))+
  labs(title="A) County population",subtitle="Delaware | ACS 2020-2024")+base_theme+
  theme(axis.text=element_blank(),axis.title=element_blank())
# Curved paired arrows retain both directions without crossing the center.
nodes <- data.frame(id=1:3,x=c(-2.4,0,2.4),y=c(-1.25,2.25,-1.25))
edges <- expand.grid(from=1:3,to=1:3); edges <- edges[edges$from!=edges$to,]
edges$value <- flow[cbind(edges$from,edges$to)]
# Pull arrow endpoints back from node centers.
dx <- nodes$x[edges$to]-nodes$x[edges$from]; dy <- nodes$y[edges$to]-nodes$y[edges$from]
d <- sqrt(dx^2+dy^2); edges$x <- nodes$x[edges$from]+.60*dx/d; edges$y <- nodes$y[edges$from]+.60*dy/d
edges$xe <- nodes$x[edges$to]-.60*dx/d; edges$ye <- nodes$y[edges$to]-.60*dy/d
B <- ggplot()+geom_curve(data=edges,aes(x=x,y=y,xend=xe,yend=ye,linewidth=value,color=value),curvature=.17,arrow=grid::arrow(length=grid::unit(.11,"inches")),lineend="round")+
  geom_point(data=nodes,aes(x,y),shape=21,size=11,fill="#F3F3F3",color="#777777",stroke=.8)+
  geom_text(data=nodes,aes(x,y,label=id),fontface="bold",size=main_mm)+
  annotate("label",x=0,y=.35,label="X %~% Binomial(S,p)",parse=TRUE,size=main_mm,linewidth=0,fill="white")+
  scale_color_gradient(low="#F7E9CB",high="#f2ad2e",name="Travel\nfraction",breaks=c(.02,.06),labels=scales::label_percent(accuracy=1))+
  scale_linewidth_continuous(range=c(.35,1.3),guide="none")+
  coord_fixed(xlim=c(-3.2,3.2),ylim=c(-2,2.8),clip="off")+
  labs(title="B) County travel network",subtitle="Q4 2019 | arrows: origin -> destination")+base_theme+
  theme(axis.text=element_blank(),axis.title=element_blank())
# Native vertical color guides keep the scale next to its own panel.
frame_panel <- function(p,title) ggdraw()+
  draw_plot(p+labs(title=NULL,subtitle=NULL),x=.02,y=.025,width=.96,height=.87)+
  draw_label(title,x=.5,y=.96,hjust=.5,fontface="bold",size=title_pt)
network_panel <- frame_panel(B,"County travel network")
cm <- expand.grid(contactor=ages,contactee=ages); cm$value <- as.vector(contact)
cm$contactor <- factor(cm$contactor,levels=ages); cm$contactee <- factor(cm$contactee,levels=ages)
C <- ggplot(cm,aes(contactee,contactor,fill=value))+geom_tile(color="white",linewidth=.7)+
  geom_text(aes(label=sprintf("%.1f",value),color=value>6),size=main_mm)+scale_color_manual(values=c("FALSE"="#333333","TRUE"="white"),guide="none")+
  scale_fill_gradient(low="#EEF0E7",high="#596246",name="Contacts/\nperson/day",breaks=c(0,5,10))+
  coord_equal()+labs(title="C) Age-specific contacts",subtitle="Mistry et al. | all settings",x="Contactee",y="Contactor")+base_theme
rd <- expand.grid(county=pop$id,age=ages); rd$value <- as.vector(as.matrix(risk[,ages]))
rd$county <- factor(rd$county,levels=rev(pop$id)); rd$age <- factor(rd$age,levels=ages)
D <- ggplot(rd,aes(age,county,fill=value))+geom_tile(color="white",linewidth=.7)+
  geom_text(aes(label=scales::percent(value,accuracy=.1)),size=main_mm)+
  scale_fill_gradient(low="#F5E8E2",high="#bd6b4f",limits=c(0,.6),name="High risk\nfraction (%)",breaks=c(0,.3,.6),labels=scales::label_number(scale=100,accuracy=1))+
  coord_fixed()+labs(title="D) County-specific high-risk fractions",subtitle="Influenza | age x county",x="Age",y="County")+base_theme
population_panel <- frame_panel(A,"County population")
contact_panel <- frame_panel(C,"Age-specific contacts")
risk_panel <- frame_panel(D,"County-specific high-risk fractions")
# Solid arrows are disease progression. Treatment allocation is a separate,
# stockpile-constrained transfer and is intentionally drawn dashed.
arrow_tip <- grid::arrow(length=grid::unit(.09,"inches"),type="closed")
compartments <- data.frame(label=c("S","E","I","R","T"),
                          x=c(.10,.36,.62,.90,.62),y=c(.76,.76,.76,.76,.40),
                          fill=c("#F3F3F3","#9CA58D","#777777","#EEF0E7","#f2ad2e"))
progression <- data.frame(x=c(.16,.42,.68,.68),y=c(.76,.76,.76,.43),
                          xe=c(.30,.56,.84,.87),ye=c(.76,.76,.76,.69))
compartment_plot <- ggplot()+
  geom_segment(data=progression,aes(x=x,y=y,xend=xe,yend=ye),arrow=arrow_tip,linewidth=.65,color="#555555")+
  # Draw the dashed shaft and solid terminal arrow separately: grid otherwise
  # applies the dash pattern to the arrowhead outline too.
  annotate("segment",x=.62,y=.69,xend=.62,yend=.51,linetype="dashed",linewidth=.8,color="#bd6b4f")+
  annotate("segment",x=.62,y=.51,xend=.62,yend=.47,linetype="solid",
           arrow=grid::arrow(length=grid::unit(.12,"inches"),type="closed"),
           linewidth=.8,color="#bd6b4f")+
  geom_point(data=compartments,aes(x,y,fill=fill),shape=21,size=11,color="#555555",stroke=.6)+scale_fill_identity()+
  geom_text(data=compartments,aes(x,y,label=label),size=main_mm,fontface="bold")+
  
  annotate("text",x=.49,y=.84,label="1 day",size=main_mm)+
  annotate("text",x=.77,y=.84,label="7 days",size=main_mm)+
  annotate("label",x=(.68+.87)/2,y=(.43+.69)/2,label="5 days",
           size=main_mm,fill="white",color="#333333",linewidth=0,
           label.padding=grid::unit(.12,"lines"))+
  coord_cartesian(xlim=c(0,1),ylim=c(.23,.94),clip="off")+theme_void()
model_panel <- ggdraw()+draw_plot(compartment_plot,x=.01,y=.08,width=.98,height=.80)+
  draw_label("SEI(T)R model",x=.5,y=.96,hjust=.5,fontface="bold",size=title_pt)
top_row <- plot_grid(model_panel,population_panel,network_panel,ncol=3,
  labels=c("A","B","C"),label_size=24,label_fontface="bold",
  label_x=.01,label_y=.99,hjust=0,vjust=1)
bottom_row <- plot_grid(contact_panel,risk_panel,ncol=2,
  labels=c("D","E"),label_size=24,label_fontface="bold",
  label_x=.01,label_y=.99,hjust=0,vjust=1)
# A single continuous paragraph spans the full figure width at 11 pt.
legend_text <- paste(
  "A) S: susceptible; E: exposed; I: infectious; T: treated; R: recovered. R0 = 1.2 with no waning immunity; arrow labels give mean durations.",
  "Solid arrows show disease progression; the dashed I-to-T arrow denotes stockpile-dependent antiviral allocation (10K or 100K courses released on day 30).",
  "Treated individuals have 50% relative infectiousness. Local infection pressure is transmission per contact x contacts x (I + 0.5 T) / contacted-age population, summed over contacted ages.",
  "B) Delaware county populations are from ACS 2020-2024. C) Daily travel fractions are from Q4 2019; arrow width and color encode travel from origin to destination, with self-travel omitted.",
  "X is new travel exposures, S is susceptible residents, and p is daily travel exposure probability; binomial sampling is used with both disease models.",
  "Travel exposure combines residents visiting another county (travel fraction x contacts x I/N at the destination) and infectious visitors arriving (0.2 x travel fraction x contacts x I/N in the susceptible resident's home county).",
  "Here I/N means infectious / contacted-age population, and 0.2 is the infectious travel weight. The sum of both routes is multiplied by transmission per contact and clipped to [0,1] to give p for the unvaccinated baseline.",
  "D) Mistry et al. contacts, all settings; rows are contactors (youngest at bottom, oldest at top) and columns contactees. E) County-specific influenza high-risk fractions are matched by FIPS; cell labels show percentages to one decimal place.",
  "County labels: 1 = Kent (10001), 2 = New Castle (10003), 3 = Sussex (10005)."
)
# Wrap by rendered width, so the paragraph uses the full bottom rather than
# relying on character counts or separate columns. Use the same PDF font.
wrap_legend <- function(text,width_inches,font_pt) {
  grDevices::pdf(NULL,width=figure_width,height=figure_height,family="Helvetica")
  on.exit(grDevices::dev.off())
  words <- strsplit(text," +")[[1]]
  lines <- character(); line <- ""
  for(word in words) {
    candidate <- if(nzchar(line)) paste(line,word) else word
    width <- grid::convertWidth(grid::grobWidth(grid::textGrob(candidate,
      gp=grid::gpar(fontsize=font_pt,fontfamily="Helvetica"))),"inches",valueOnly=TRUE)
    if(width > width_inches && nzchar(line)) {lines <- c(lines,line); line <- word}
    else line <- candidate
  }
  paste(c(lines,line),collapse="\n")
}
legend_wrapped <- wrap_legend(legend_text,figure_width*.95,11)
# Size the body for clear spacing; the full caption is exported separately.
fig <- ggdraw()+draw_plot(top_row,y=.51,height=.49)+
  draw_plot(bottom_row,y=.015,height=.485)
caption_lines <- length(strsplit(legend_wrapped,"\n",fixed=TRUE)[[1]])
caption_height <- .65 + caption_lines * 11 * 1.5 / 72
caption_fig <- ggdraw()+draw_label(legend_wrapped,x=.025,y=1-.20/caption_height,
  hjust=0,vjust=1,size=11,lineheight=1.2,fontfamily="Helvetica")
ggsave(file.path(figure_dir,"Delaware_inputs_5panel.png"),fig,width=figure_width,height=figure_height,dpi=figure_dpi,bg="white")
ggsave(file.path(figure_dir,"Delaware_inputs_5panel.pdf"),fig,width=figure_width,height=figure_height,device="pdf",bg="white")
ggsave(file.path(figure_dir,"Delaware_inputs_caption.png"),caption_fig,width=figure_width,height=caption_height,dpi=figure_dpi,bg="white")
ggsave(file.path(figure_dir,"Delaware_inputs_caption.pdf"),caption_fig,width=figure_width,height=caption_height,device="pdf",bg="white")
writeLines(legend_text,file.path(out,"figure_text_legend.txt"))
write.csv(pop,file.path(out,"county_key_population.csv"),row.names=FALSE)
write.csv(risk,file.path(out,"county_high_risk_fractions.csv"),row.names=FALSE)
write.csv(edges[,c("from","to","value")],file.path(out,"directed_travel_edges.csv"),row.names=FALSE)
writeLines(c(
"Delaware input data and SEI(T)R model for the illustrative three-county example. Counties: 1 = Kent (10001), 2 = New Castle (10003), 3 = Sussex (10005).",
"A: S = susceptible, E = exposed (not yet infectious), I = infectious, T = treated infectious, R = recovered. Mean durations are 1 day exposed, 7 days infectious without treatment, and 5 days to recovery after treatment. Treated individuals have 0.5 times the infectiousness of untreated individuals. Solid arrows show disease progression; the dashed I-to-T arrow is allocation from an antiviral stockpile, not a fixed disease transition rate. The example releases 10,000 or 100,000 courses on day 30. There is no waning immunity. R0 = 1.2 is the baseline model input.",
"B: Total county population from ACS 2020-2024.",
"C: Directed daily travel fractions from Q4 2019; arrow width and color encode off-diagonal mobility-matrix entries. Self-travel is omitted. New travel exposures are sampled as X_ai ~ Binomial(S_ai, p_ai), where X_ai is the number of new exposures among susceptible residents of county a and age i, S_ai is the susceptible count in that subgroup, and p_ai is its daily travel exposure probability. The displayed calculation is for the unvaccinated baseline with unit susceptibility, rho, and flow modifiers. It sums exposure from residents visiting other counties and exposure from infectious visitors arriving in their home county. The 0.2 multiplier is the configured infectious travel weight, not vaccine effectiveness or transmission probability.",
"Explicit baseline travel equations: p_ai = min(1, max(0, p_visit_ai + p_arrive_ai)); p_visit_ai = beta * sum_{b != a} sum_j f_ab * C_ij * I_bj / N_bj; p_arrive_ai = 0.2 * beta * sum_{b != a} sum_j f_ba * C_ij * I_bj / N_aj. Here a is the susceptible resident's home county; b is another county; i is the susceptible (contactor) age group; j is the contacted (contactee) age group; beta is transmission probability per contact; f_ab is the daily travel fraction from a to b; C_ij is contacts made by age i with age j; I_bj is untreated infectious people of age j in county b; N_bj and N_aj are the entire age-j populations in counties b and a, respectively. The first route uses the contacted-age population at the visited destination; the second uses that population in the susceptible resident's home county. Sums cover all other counties and contacted ages. When treatment is present, the code uses the configured compartment weights in the transmitting/traveling infectious totals; the displayed travel explanation is the untreated baseline. Vaccination multiplies the exposure probability by (1-VE) for vaccinated susceptible people before clipping.",
"D: Mistry et al. contact matrix, all settings. Rows are contactor ages and columns are contactee ages. Local baseline infection pressure for a susceptible person of age i in county a is lambda_ai = beta * sum_j C_ij * (I_aj + 0.5*T_aj) / N_aj; lambda is the local force of infection, T_aj is treated infectious people of age j in county a, and other symbols are defined above. Susceptibility, vaccine, and contact modifiers apply as configured.",
"E: County-specific influenza high-risk fractions, joined by county FIPS. These are the same county-specific age fractions used in all current illustrative simulation scenarios."
),file.path(out,"caption.txt"))
cat("Saved",file.path(figure_dir,"Delaware_inputs_5panel.png"),"\n")
