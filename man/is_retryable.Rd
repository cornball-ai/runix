% tinyrox says don't edit this manually, but it can't stop you!
\name{is_retryable}
\alias{is_retryable}
\title{Is a condition retryable?}
\usage{
is_retryable(cond)
}
\arguments{
\item{cond}{A condition object.}
}
\value{
\code{TRUE} if any of the condition's classes is registered
  retryable, else \code{FALSE}.
}
\description{
Is a condition retryable?
}
\examples{
register_retryable("pkgstate_cache_race")
e <- structure(class = c("pkgstate_cache_race", "runix_error", "error",
    "condition"), list(message = "x"))
is_retryable(e)
}
