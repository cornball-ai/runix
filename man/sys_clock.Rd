% tinyrox says don't edit this manually, but it can't stop you!
\name{sys_clock}
\alias{sys_clock}
\title{A UTC wall-clock function}
\usage{
sys_clock()
}
\value{
A function of no arguments returning the current time as a
  \code{POSIXct} in UTC. Injectable so callers (and tests) can substitute a
  fixed clock.
}
\description{
A UTC wall-clock function
}
\examples{
clk <- sys_clock()
inherits(clk(), "POSIXct")
}
