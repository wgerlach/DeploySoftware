#!/usr/bin/env perl

use strict;
use warnings;

use Cwd 'abs_path';
use Getopt::Long;
use File::Basename;
eval "use JSON; 1"
or die "perl module required, e.g.: sudo apt-get install cpanminus ; sudo cpanm install JSON";

use File::Temp;
#use LWP::UserAgent;
use Data::Dumper;

1;



my $target = "/home/ubuntu/";

my $default_repository = 'https://raw.github.com/wgerlach/DeploySoftware/master/repository.json';

#########################################
my %already_installed;
my $h = {};

sub systemp {
	print "cmd: ".join(' ', @_)."\n";
	return system(@_);
}

sub modifyINIfile {
	my ($inifile, $ini_hash) = @_;
	
	print "read INI-file $inifile\n";
	
	eval "require Config::IniFiles; 1" # cpanm install Config::IniFiles
	or die "perl module required, e.g.: sudo apt-get install cpanminus ; sudo cpanm install Config::IniFiles";
	
	
	my $cfg = Config::IniFiles->new( -file => $inifile );
	
	foreach my $section (keys %$ini_hash) {
		my $section_hash = $ini_hash->{$section};
		foreach my $key (keys %$section_hash) {
			my $value = $section_hash->{$key};
			
			setINIvalue($cfg, $section, $key, $value);
			
		}
	}
	
	print "write INI-file $inifile\n";
	$cfg->WriteConfig($inifile);
	
}

sub setINIvalue {
	my ($cfg, $section, $key, $value) = @_;
	
	
	if ($cfg->exists($section, $key)) {
		$cfg->setval($section, $key, $value);
	} else {
		$cfg->newval($section, $key, $value);
	}
	
}

#example:[section]key=value?key=value...
sub INI_cmds_to_hash {
	
	my $strings = shift(@_);
	
	my $ini_hash={};
	foreach my $parameter (@{$strings}) {
		my ($section, $pair_string) = $parameter =~ /^\[(\S+)\](.*)$/;
		
		unless (defined $section && defined $pair_string) {
			print $parameter."\n";
			die;
		}
		
		my @pairs = split('\?', $pair_string);
		if (@pairs == 0) {
			die;
		}
		
		foreach my $pair (@pairs) {
			my ($key, $value) = split('=', $pair);
			unless (defined $key && defined $value) {
				print $parameter." , ".$pair."\n";
				die;
			}
			$ini_hash->{$section}->{$key} = $value;
		}
		
	}
	
	
	return  $ini_hash;
}




sub downloadFile {
	my %args = @_;
	
	my $url = $args{'url'};
	my $dir = $args{'target-dir'};
	my $targetname = $args{'target-name'};
	#my $output = $args{'output'};

	unless (defined $dir) {
		die;
	}
	
	unless (defined $url) {
		die;
	}
	
	if (substr($dir, -1, 1) ne '/') {
		$dir .= '/';
	}
	
	
	my $file;
	unless (defined $targetname) {
		
		my $basefilename = (split qr{/}, $url)[-1];  # detect filename if possible
		
		unless (defined $basefilename) {
			die "filename could not be detected from url $url";
		}
		
		
		$targetname = $basefilename;
	}
	
	$file = $dir. $targetname;
	
	if (-e $file) {
		if (defined($h->{'new'}) || definedAndTrue($h->{'remove-existing-file'})) {
			systemp("rm -f $file");
		} else {
			print "skip file: $file already exists....\n";
			return $file;
		}
	}
	
	
	systemp("cd $dir && curl -L -o $targetname --retry 1 --retry-delay 5 \"$url\"") == 0 or die;
	
	unless (-s $file) {
		die "file $file was not downloaded!?";
	}
	
	#my $fh = File::Temp->new(DIR => $dir, TEMPLATE => 'temp_XXXXXXXXX');
	#my $fname = $fh->filename;
	
	return $file;
	
}

sub process_scalar {
	my $text = shift;
	
	$text =~ s/\$target/$target/g ;
	$text =~ s/\$\{target\}/$target/g ;
	
	return $text;
}

sub datastructure_walk {
    my %arghash = @_;
	my $datastructure = $arghash{'data'};
	my $sub = $arghash{'sub'};
	my $arg = $arghash{'subarg'};
	
	my $show=0;
	
	if (ref($datastructure) eq 'HASH') {
		while (my ($k, $v) = each %$datastructure) {
			if ($show==1) {print "goto $k\n";}
			if (ref($v) eq '') {
				#print "scalar: ".$datastructure->{$k}."\n";
				$datastructure->{$k} = $sub->($v, $arg);
				#print "scalar: ".$datastructure->{$k}."\n";
			} else {
				unless (defined($arghash{'nosubpackages'}) && $k eq "subpackages") {
					datastructure_walk('data' => $v, 'sub' => $sub, 'subarg' => $arg);
				}
			}
		}
	} elsif (ref($datastructure) eq 'ARRAY') {
		for (my $i = 0 ; $i < @$datastructure ; $i++ ) {
			if (ref($datastructure->[$i]) eq '') {
				#print "scalar: ".$datastructure->[$i]."\n";
				$datastructure->[$i] = $sub->($datastructure->[$i], $arg);
				#print "scalar: ".$datastructure->[$i]."\n";
			} else {
				datastructure_walk('data' => $datastructure->[$i], 'sub' => $sub, 'subarg' => $arg);
			}
		}
	
	} elsif (ref($datastructure) ne '') {
		die "got: ".ref($datastructure);
	} else {
		# non-ref scalar !?
		print "scalar: $datastructure\n";
		die;
		
	}
	
	return;
}


sub setenv {
	my ($key, $value) = @_;
	my $envline = "export $key=$value";
	#systemp("grep -q -e '$envline' ~/.bashrc || echo '$envline' >> ~/.bashrc");
	
	bashrc_append($envline);
	
	if ($value =~ /\$/ || $value =~ /\~/) {
		#make sure that environment variables are evaluated
		my $echocmd = "echo \"$value\"";
		$value = `$echocmd`;
		chomp($value);
	}
	
	$ENV{$key}=$value; # makes sure variable can be used even if bashrc is not sourced yet.
	return;
}


sub bashrc_append {
	my $line = shift(@_);
	
	systemp("grep -q -e '$line' ~/.bashrc || echo '$line' >> ~/.bashrc");
	
}

sub git_clone {
	my ($source, $dir) = @_;
	
	
	my $gitname;
	
	#example git://github.com/qiime/qiime-deploy.git
	#example kbase@git.kbase.us:dev_container
	$gitname = (split(/\/|:/, $source))[-1]; # split on "/" and ":"
	
	if ($gitname =~ /\.git$/) { # remove .git suffix
		($gitname) = $gitname =~ /(.*)\.git/;
	}
		
	unless (defined $gitname){
		die "git string unkown: $source";
	}
	
	my $gitdir = $dir.$gitname.'/';
	
	if (-d $gitdir) {
		if (defined $h->{'update'}) {
			systemp("cd $gitdir && git pull") == 0 or die;
			return $gitdir;
		}
		if (defined $h->{'new'}) {
			systemp("rm -rf $gitdir") == 0 or die;
		}
	}
	systemp("cd $dir && git clone $source") == 0 or die;
	
	return $gitdir;
}

sub hg_clone {
	my ($source, $dir) = @_;
	
	my $hgname = (split('/', $source))[-1];
	
	unless (defined $hgname) {
		die;
	}
	
	my $hgdir = $dir.$hgname;
	
	if (-d $hgdir) {
		if (defined $h->{'update'}) {
			systemp("cd $hgdir && hg update") == 0 or die;
			return $hgdir;
		}
		if (defined $h->{'new'}) {
			systemp("rm -rf $hgdir") == 0 or die;
		}
	}
	
	systemp("cd $dir && hg clone ".$source) == 0 or die;
	
	return $hgdir;
}


# replaces ${i} variables
sub replaceArguments {
	my $exec = shift(@_);
	my $package_args_ref = shift(@_);
	
	unless (defined $package_args_ref) {
		$package_args_ref=[];
	}
	
	print "exec: $exec\n";
	print "package_args: ".@$package_args_ref."\n";
	
	
	for (my $i = 0 ; $i < @$package_args_ref; $i++) {
		my $k = $i+1;
		my $j = $package_args_ref->[$i];
		
		#print "j: ".$j."\n";
		$exec =~ s/\$\{$k\}/$j/g;
	}
	
	my $package_args_string = join(' ', @$package_args_ref);
	$exec =~ s/\$\{arguments\}/$package_args_string/g;
	
	
		
	
	print "exec: $exec\n";
	return $exec;
}

sub replaceVersionNumbers {
	my $exec = shift(@_);
	my $version_numbers_ref = shift(@_);
	
	unless (defined $version_numbers_ref) {
		return $exec;
	}
	
	print 'ref: '.ref($version_numbers_ref)."\n";
	
	print "exec: $exec\n";
	print "version_numbers: ".@$version_numbers_ref."\n";
	if (@$version_numbers_ref > 0) {
		for (my $i = 0 ; $i < @$version_numbers_ref; $i++) {
			my $k = $i+1;
			my $j = $version_numbers_ref->[$i];
			
			#print "j: ".$j."\n";
			$exec =~ s/\$\{v$k\}/$j/g;
		}
	} else {
		die;
	}
	print "exec: $exec\n";
	return $exec;
}

sub replacePtarget {
	my $exec = shift(@_);
	my $ptarget = shift(@_);
	
	unless (defined $ptarget) {
		die;
	}
	
	#print 'ref: '.ref($version_numbers_ref)."\n";
	
	print "exec: $exec\n";
	$exec =~ s/\$\{ptarget\}/$ptarget/g;
	
	print "exec: $exec\n";
	return $exec;
}


sub parsePackageString{
	my $package_string = shift(@_);
	
	print "package_string: $package_string\n";
	
	my $package = undef;
	my ($p, $package_arg_line) = $package_string =~ /^(.*)(\(.*\))$/;
	
	my @package_args=();
	if (defined $package_arg_line) {
		$package = $p;
		$package_arg_line= $package_arg_line =~ /^\((.*)\)$/;
		print "package_arg_line: $package_arg_line\n";
		
		if (defined $package_arg_line && $package_arg_line ne "") {
			@package_args = split(' ', $package_arg_line) ;
		}

		
	} else {
		$package = $package_string;
	}
	
	print "package_args_got: ".join(',', @package_args)."\n";
	
	
	my $argref = undef;
	if (@package_args > 0) {
		$argref = \@package_args;
	}

	
	my ($p2, $version) = $package =~ /^(.*)\=\=(.*)$/;
	
	if (defined $p2 && defined $version) {
		$package = $p2;
		
		my @version_array = split(/\./, $version); # make it an array_ref
		
		if (@version_array == 0) {
			die "version string parsing failed: \"$version\"";
		}
		
		$version = \@version_array;
		
	} else {
		$version = undef;
	}
	
	
	return ($package, $version, $argref);
	
}


my $functions = {};


sub function_kbasemodules {
	my %arghash = @_;
	
	my $server = $arghash{'server'} or die;
	my $target = $arghash{'target'} or die;
	my $package_list = $arghash{'package-list'} || "";
	
	
	if (substr($target, -1, 1) ne "/") {
		$target .= '/';
	}
	
	my @kbase_modules = split(' ', $package_list);
	
	my $downloaded_modules = {};
	while (@kbase_modules > 0) {
		my $module = shift(@kbase_modules);
		unless (defined $downloaded_modules->{$module}) {
			my $gitdir = git_clone($server.$module, $target);
			$downloaded_modules->{$module} = 1;
			
			
			
			my $filename = $gitdir.'DEPENDENCIES';
			if (-e $filename) {
				open my $fh, "<", $filename
				or die "could not open $filename: $!";
				my @deps = <$fh>;
				chomp(@deps);
				push(@kbase_modules, @deps);
			}
				
			
			
			
		}
		
	}
	
	
}

$functions->{'kbasemodules'} = \&function_kbasemodules;


sub definedAndTrue {
	my $x = shift(@_);
	if (defined $x && $x == 1) {
		return 1;
	}
	return 0;
}

sub get_array {
	my $ref = shift(@_);
	my @array;
	
	if (ref($ref) eq 'ARRAY' ) {
		@array = @{$ref};
	} else {
		@array = ($ref);
	}
	
	return @array;
}


sub install_package {
	my ($repository, $package_hash, $package, $version, $package_args_ref) = @_;
	
	#print 'ref1: '.ref($version)."\n";
	print "$package: ". Dumper($package_hash);
	
	if (definedAndTrue($package_hash->{'ignore'})) {
		print STDERR "package $package ignored.\n";
		return;
	}
	
	if (defined $package_hash->{'ignore'}) {
		die;
	}
	
	# replace arguments if they have been used
	datastructure_walk('data' => $package_hash, 'sub' => \&replaceArguments, 'subarg' => $package_args_ref);
	
	
	print "install package: $package\n";
	print "args: ".join(' ',@$package_args_ref)."\n" if defined $package_args_ref;
	
	
	unless (defined $package_hash) {
		print STDERR "error: no configuration found for package $package\n";
		exit(1);
	}
	
	# START installation ########################
	#if (defined $already_installed{$package} && $already_installed{$package}==1) {
	if (definedAndTrue($already_installed{$package})) {
		print "package $package already installed, skip it...\n";
		next;
	}
	
	if (defined $version) {
		print 'ref2: '.ref($package_hash->{'version'})."\n";
		$package_hash->{'version'} = $version;
	}
	if ((defined $package_hash->{'version'}) && ($package ne "subpackage")) {
		print 'ref3: '.ref($package_hash->{'version'})."\n";
		datastructure_walk('data' => $package_hash, 'sub' => \&replaceVersionNumbers, 'subarg' => $package_hash->{'version'});
	}
	
	my $ptarget = $package_hash->{'ptarget'} || $target;
	if (substr($ptarget, -1, 1) ne '/') {
		$ptarget .= '/';
	}
	if (defined($package_hash->{'ptarget'})) {
		datastructure_walk('data' => $package_hash, 'sub' => \&replacePtarget, 'subarg' => $ptarget, 'nosubpackages' => 1);
	}
	
	if (definedAndTrue($package_hash->{'dir'}) && defined($package_hash->{'ptarget'})) {
		die;
	}
	if (definedAndTrue($package_hash->{'dir'})) {
		$ptarget .= $package.'/';
		$package_hash->{'ptarget'} = $ptarget;
	}
	

	unless (-d $ptarget) {
		systemp("mkdir -p ".$ptarget);
	}

	
	#dependencies
	if (defined $package_hash->{'depends'}) {
		foreach my $dependency (@{$package_hash->{'depends'}}) {
			
			my ($dep_package, $dep_version, $dep_package_args_ref) = parsePackageString($dependency);
			
			if ( definedAndTrue( $already_installed{$package} ) ) {
				print "dependency $dependency already installed\n";
			}else {
				print "install dependency $dependency for $dep_package...\n";
				install_package($repository, $repository->{$dep_package}, $dep_package, $dep_version, $dep_package_args_ref);
			}
		}
	}
	
	
		
	
	#print "chdir $ptarget\n";
	chdir($ptarget);
	
	#subpackages
	if (defined $package_hash->{'subpackages'}) {
		my $subpackages =$package_hash->{'subpackages'};
		foreach my $subpackage (@{$subpackages}) {
			if (defined($package_hash->{'ptarget'}) && ! defined($subpackage->{'ptarget'})) { # inherit ptarget
				$subpackage->{'ptarget'} = $package_hash->{'ptarget'};
			}
			print "install subpackage for $package...\n";
			install_package($repository, $subpackage, "subpackage", $version, $package_args_ref); #recursive !
		}
	}
	
	#print "chdir $ptarget\n";
	chdir($ptarget);
	
	if ($package_hash->{'depend-function'}) {
		
		foreach my $function_hash (@{$package_hash->{'depend-function'}}) {
			my $function_name = $function_hash->{'name'};
			&{$functions->{$function_name}}(%$function_hash);
		}
		
		
	}
	
	
	if (defined $package_hash->{'source-as-parameter'} && $package_hash->{'source-as-parameter'} ==1) {
		if (defined $package_args_ref) {
			push(@{$package_hash->{'source'}}, @{$package_args_ref});
			print "source total: ".join(',', @{$package_hash->{'source'}})."\n";
		}
	}

	if (defined $package_hash->{'source'}) {
		my @sources = get_array($package_hash->{'source'});
		
		my $build_type = $package_hash->{'build-type'} || 'exec';
		
		my $source_type = $package_hash->{'source-type'} || 'auto';
		foreach my $source_obj (@sources) {
			
			my $source;
			my $source_filename;
			my $source_subdir;
			if (ref($source_obj) eq 'HASH') {
				$source = $source_obj->{'url'};
				$source_subdir = $source_obj->{'subdir'};
				$source_filename=$source_obj->{'filename'};
			} else {
				$source = $source_obj;
			}
			
			
			# detect source type
			my $st = $source_type;
			if ($st eq 'auto') {
				#autodetect source type
				if ($source =~ /^git:\/\//) {
					$st = 'git';
				} elsif (defined($package_hash->{'git-server'})) {
					$st = 'git';
				} elsif ($source =~ /^http.*\.git/) {
					$st = 'git';
				} elsif ($source =~ /^ssh.*\.git/) {
					$st = 'git';
				} else {
					$st='download';
				}
				
			}
			
			my $temp_dir_obj = undef;
			my $temp_dir = $ptarget;
			my $sourcedir=undef;
			my $downloaded_file=undef;
			if ($st eq 'git' && defined($package_hash->{'git-server'})) {
				$source = $package_hash->{'git-server'}.$source;
			}
			
			if (definedAndTrue($package_hash->{'source-temporary'})) {
				$temp_dir_obj = File::Temp->newdir( TEMPLATE => 'deployXXXXX' );
				$temp_dir = $temp_dir_obj->dirname.'/';
			}
			
			if ($st eq 'git' || $st eq 'mercurial' || $st eq 'go') {
				
				
				
				
				
				
				if ($st eq 'git') {
					$sourcedir = git_clone($source, $temp_dir);
				} elsif ($st eq 'mercurial') {
					$sourcedir = hg_clone($source, $temp_dir);
				} elsif ($st eq 'go') {
					#-fix -u  github.com/MG-RAST/AWE/...
					
					my $update_works = 0;
					if (defined $h->{'update'}) {
						if (systemp("go get -fix -u ".$source) == 0){
							$update_works = 1;
						}
					}
					
					if (defined $h->{'new'}) {
					#rm -rf gopath/src/github.com/
						if (defined $ENV{GOPATH} && -d $ENV{GOPATH} ) {
							my $src_dir = $ENV{GOPATH}.'/src/'.$source;
							while (substr($src_dir, -1, 1) eq'.') {
								chop($src_dir);
							}
							if (-d $src_dir) {
								systemp("rm -rf ".$src_dir)
							}
						}
						if (defined $ENV{GOPATH} && ! -d $ENV{GOPATH} ) {
							systemp("mkdir -p ".$ENV{GOPATH});
						}
						
					}
					if ($update_works == 0) {
						systemp("go get ".$source) == 0 or die;
					}
				} else {
					die;
				}
				
				
			} elsif ($st eq 'apt') {
				systemp("sudo apt-get --force-yes -y install ".$source);
			} elsif ($st eq 'download') {
				#simple download
				
				$downloaded_file = downloadFile('url' => $source,
												'target-dir' => $ptarget,
												'target-name' => $source_filename,
												'remove-existing-file' => $package_hash->{'source-remove-existing-file'});
				unless (defined $downloaded_file) {
					die;
				}
				
				if (definedAndTrue($package_hash->{'source-extract'})) {
					if ($downloaded_file =~ /\.tar\.gz$/) {
						systemp("tar xvfz ".$downloaded_file." -C ".$temp_dir);
					} elsif ($downloaded_file =~ /\.tgz$/) {
						systemp("tar xvfz ".$downloaded_file." -C ".$temp_dir);
					} elsif ($downloaded_file =~ /\.zip$/) {
						systemp("unzip ".$downloaded_file." -d ".$temp_dir);
					} else {
						die "unknown archive: $downloaded_file";
					}
					$sourcedir=$temp_dir;
				}
				
			} else {
				die;
			
			}
			
			
			my $build_dir;
			# different build-types
			if (defined($package_hash->{'build-exec'})) {
				my $exec = $package_hash->{'build-exec'};
				if (defined $downloaded_file) {
					$exec =~ s/\$\{source-file\}/$downloaded_file/g;
				}
				
				if (defined $sourcedir) {
					$exec =~ s/\$\{source-dir\}/$sourcedir/g;
				}
				print "build-exec:\n";
				systemp($exec) == 0 or die;
				
			} elsif ($build_type eq 'make-install' || $build_type eq 'make'){
				
				$build_dir = $sourcedir;
				
				if (defined $source_subdir) {
					$build_dir .= $source_subdir;
				}
				
				
				# change directory if needed
				#if (! -e $build_dir.'configure' && -e $build_dir.'Makefile' ) {
				#	opendir my $dir, "/some/path" or die "Cannot open directory: $!";
				#	my @files = readdir $dir;
				#	closedir $dir;
				#	print join(',', @files)."\n";
				#	die;
				#
				#}
				
				
				if (substr($build_dir,-1,1) ne '/') {
					$build_dir .= '/';
				}
				
				if (-e $build_dir.'configure') {
					systemp("cd $build_dir && ./configure --prefix=$ptarget") == 0 or die;
				}
				
				if (-e $build_dir.'Makefile') {
					systemp("cd $build_dir && make")== 0 or die; #TODO make -j4
				} else {
					die "Makefile in $build_dir not found";
				}
				if ($build_type eq 'make-install') {
					if (-e $build_dir.'Makefile') {
						systemp("cd $build_dir && make install")== 0 or die; #TODO make -j4
					} else {
						die "Makefile in $build_dir not found";
					}
				}
				
			} else {
				# no build
			}
			
			
			if (defined($package_hash->{'install-type'})) {
				
				unless (defined $build_dir) {
					die;
				}
				
				if ($package_hash->{'install-type'} eq "copy") {
					print "install-type: copy\n";
					if (defined($package_hash->{'install-files'})) {
						my $install_files_obj = $package_hash->{'install-files'};
						my @install_files_array = get_array($install_files_obj);
						
						foreach my $install_file (@install_files_array) {
							
							unless (-e $build_dir.$install_file) {
								die "installation file $build_dir.$install_file not found";
							}
							
							systemp("cp -f $build_dir".$install_file." $ptarget") == 0 or die;
							
						}
						
					} else {
						die;
					}
				} else {
					die;
				}
			}
			
			
			
			#temp_dir goes out of scope here
		}
		
	}


	if (defined $package_hash->{'set-env'}) {
		my $env_pairs = $package_hash->{'set-env'};
		foreach my $key (keys %{$env_pairs} ) {
			setenv($key, $env_pairs->{$key}) ;
		}
	}
	
	
	if (defined($package_hash->{'set-ini-values'})) {
		
		print "set-ini-values\n";
		
		my $inifile = $package_hash->{'set-ini-values'}->{'file'};
		unless (defined $inifile || ! -e $inifile) {
			die "INI-file $inifile not defined or not found";
		}
		
		my $cfg_string = $package_hash->{'set-ini-values'}->{'cfg-string'} || "";
		
		if ($cfg_string ne "") {
			
			print "cfg_string: \"$cfg_string\"\n";
			my $ini_hash = INI_cmds_to_hash( [ $cfg_string ] );
			modifyINIfile($inifile, $ini_hash)
		}else {
			print STDERR "warning: cfg_string emtpy, will not modify $inifile\n";
		};
		
	} else {
		print "set-ini-values not defined !?\n";
		print Dumper($package_hash);
		
	}
	
	if (defined $package_hash->{'bashrc-append'}) {
		my @lines;
		if (ref($package_hash->{'bashrc-append'}) eq 'ARRAY') {
			@lines = @{$package_hash->{'bashrc-append'}};
		} else {
			@lines = ($package_hash->{'bashrc-append'});
		}
		foreach my $line (@lines) {
			bashrc_append($line) ;
		}
		
	}
	
	
	if (defined $package_hash->{'exec'}) {
		
		my @execs;
		if (ref($package_hash->{'exec'}) eq 'ARRAY') {
			@execs = @{$package_hash->{'exec'}};
		} else {
			@execs = ($package_hash->{'exec'});
		}
		foreach my $exec (@execs) {
			
			print "exec:\n";
			systemp($exec) == 0 or die;
		}
	}
	
	if (defined $package_hash->{'test'}) {
		print "test_exec:\n";
		systemp($package_hash->{'test'}) == 0 or die;
	}
	

	unless ($package eq "subpackage") {
		$already_installed{$package} = 1;
	}
	
	#if (defined $package_hash->{'finish-package'}) {
	#	if (ref($package_hash->{'finish-package'}) eq 'ARRAY' ) {
	#		return $package_hash->{'finish-package'};
	#	} else {
	#		return ($package_hash->{'finish-package'});
	#	}
	#}
	
}

#############################################################


GetOptions ($h, 'target=s', 'version=s', 'update', 'new', 'root', 'all', 'repository=s', 'ignore=s');

unless ( @ARGV  || @ARGV > 1) {
	print "usage: deploy_software.pl [--target=] [packages]\n";
	#print "default target=$target\n";
	print "example: deploy_software.pl --target=/home/ubuntu/ aweclient\n";
	print "     --update to update existing repositories if possible \n";
	print "     --new to delete repositories before cloning \n";
	print "     --all to install all packages in repository \n";
	print "     --ignore=package1,package2\n";
	exit 1;
}


if (defined $h->{'update'} && defined $h->{'new'} ) {
	die;
}


if ( ! defined($h->{'root'}) && ($< == 0) ) {
	print "error: please do not run me as root unless you know what you are doing.\n";
	exit(0);
}

if (defined($h->{'root'}) &&  ($< != 0) ) {
	print "error: you gave option --root but you are not root.\n";
	exit(0);
}

#my $target = "/kb/runtime/";

# in case we use cached installation
#maybe add to .bashrc : source /home/ubuntu/data/qiime_software/activate.sh

#cd data && wget ftp://ftp.metagenomics.anl.gov/data/misc/private/wolfgang_epaghsmh/qiime_software.tar.gz


if (defined $ENV{'TARGET'} ) {
	$target = $ENV{'TARGET'};
}

if (defined $h->{'target'}) {
	$target = $h->{'target'};
}


unless (defined $target) {
	$target = getcwd();
}

if (substr($target, -1, 1) ne "/") {
	$target .= "/";
}

if (defined $target) {
	unless (-d $target) {
		die "target \"$target\" not found!\n";
	}
} else {
	die;
}





my $repository_json = <<'EOF';
{
	xxxxx
}
EOF

#my $package_rules = decode_json($package_rules_json);
my $repository = undef;


my $use_repository;
if (defined $h->{'repository'}) {
	$use_repository = $h->{'repository'};
} else {
	$use_repository = $default_repository;
}

print "fetching repository: ".$use_repository."\n";
my $curl_cmd = "curl -S -s -o /dev/stdout ".$use_repository;
$repository_json = `$curl_cmd`;
chomp($repository_json);


$repository = decode_json($repository_json);


datastructure_walk('data' => $repository, 'sub' => \&process_scalar); # for my "environment variables"... ;-)



my @package_list = @ARGV;

print "target: $target\n";


if (defined($h->{'ignore'})) {
	my @ignorepackages = split(',', $h->{'ignore'});
	foreach my $p (@ignorepackages) {
		if (defined($repository->{$p})) {
			$repository->{$p}->{'ignore'} = 1;
			print "ignore package $p requested\n";
		} else {
			die "package $p not found";
		}
	}
}




foreach my $package_string (@package_list) {
	
	my ($package, $version, $package_args_ref) = parsePackageString($package_string);
	
	my $pack_hash = $repository->{$package};
	unless (defined $pack_hash) {
		print "repository:\n";
		foreach my $p (keys(%$repository)) {
			print "$p\n";
		}
		print "\n";
		
		die "package $package not found\n";
	}
	
	install_package($repository, $pack_hash, $package, $version, $package_args_ref);
	
}

print "all packages installed.\n";










