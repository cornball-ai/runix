% tinyrox says don't edit this manually, but it can't stop you!
\name{register_retryable}
\alias{register_retryable}
\title{Register retryable condition classes}
\usage{
register_retryable(...)
}
\arguments{
\item{...}{Condition class names that are safe to retry.}
}
\value{
Invisibly, the full set of registered retryable classes.
}
\description{
Register retryable condition classes
}
\examples{
register_retryable("pkgstate_cache_race")
}
