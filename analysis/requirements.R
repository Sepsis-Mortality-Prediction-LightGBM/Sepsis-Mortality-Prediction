# Recorded runtime specification; this file checks versions and installs nothing.
required_R_version <- "4.6.1"
required_packages <- c(svglite="2.2.2")
stopifnot(as.character(getRversion()) == required_R_version)
for (package in names(required_packages)) {
  stopifnot(requireNamespace(package, quietly=TRUE))
  stopifnot(as.character(packageVersion(package)) == required_packages[[package]])
}
