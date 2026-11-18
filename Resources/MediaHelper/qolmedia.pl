# Loads QoL Notch's now-playing helper inside the system Perl. See qolmedia.m for why.
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "Could not load helper: " . DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "qol_run") or die "Helper is missing its entry point";
DynaLoader::dl_install_xsub("main::qol_run", $sym);
main::qol_run();
