use 5.008001;
use strict;
use warnings;

package EvergreenConfig;

use base 'Exporter';

# CPAN::Meta::YAML is a clone of YAML::Tiny and is available in Perl 5.14+
use CPAN::Meta::YAML;
use List::Util 1.45 qw/any uniq/;
use Tie::IxHash;

our @EXPORT = qw(
  assemble_yaml
  buildvariants
  ignore
  pre
  post
  task
  timeout
);

# Constants

my @unix_perls =
  map { $_, "${_}t", "${_}ld" } qw/10.1 12.5 14.4 16.3 18.4 20.3 22.2 24.0/;
my @win_perls = qw/ 14.4 16.3 18.4 20.3 22.2 24.0/;

my @win_dists = (
##    ( map { ; "windows-64-$_-compile", "windows-64-$_-test" } qw/vs2010 vs2013/ ),
    ( map { ; "windows-64-vs2015-$_" } qw/compile test large/ )
);

# perlroot: where perls are installed. E.g. /opt/perl or c:/perl
# binpath: dir under perlroot/$version to find perl binary. E.g. 'bin' or 'perl/bin'
my %os_map = (
    ubuntu1604 => {
        name     => "Ubuntu 16.04",
        run_on   => [ 'ubuntu1604-test', 'ubuntu1604-build' ],
        perlroot => '/opt/perl',
        perlpath => 'bin',
        perls    => \@unix_perls,
    },
    'windows64' => {
        name     => "Win64",
        run_on   => \@win_dists,
        perlroot => '/cygdrive/c/perl',
        perlpath => 'perl/bin',
        ccpath   => 'c/bin',
        perls    => \@win_perls,
    },
);

# Load functions from DATA
my %functions;
{
    my $current_name;
    my $current_body;
    while ( my $line = <DATA> ) {
        if ( $line =~ m{^"([^"]+)"} ) {
            $functions{$current_name} = $current_body if $current_name;
            ( $current_name, $current_body ) = ( $1, "  $line" );
        }
        else {
            $current_body .= "  $line";
        }
    }
    $functions{$current_name} = $current_body if $current_name;
}

# Functions

sub assemble_yaml {
    return join "\n", map { _yaml_snippet($_) } _default_headers(), @_;
}

sub buildvariants {
    my ($tasks) = @_;
    my (@functions_found);

    # Pull out task names for later verification of dependencies
    my @task_names = grep { $_ ne 'pre' && $_ ne 'post' } map { $_->{name} } @$tasks;
    my %has_task = map { $_ => 1 } @task_names;

    # verify the tasks are valid
    for my $t (@$tasks) {
        my @cmds = @{ $t->{commands}   || [] };
        my @deps = @{ $t->{depends_on} || [] };

        my @fcns = map { $_->{func} } @cmds;
        push @functions_found, @fcns;

        my @bad_fcns = grep { !defined $functions{$_} } @fcns;
        die "Unknown function(s): @bad_fcns\n" if @bad_fcns;

        my @bad_deps = grep { !defined $has_task{$_} } map { $_->{name} } @deps;
        die "Unknown dependent task(s): @bad_deps\n" if @bad_deps;
    }

    # assemble the list of functions
    return (
        _assemble_functions(@functions_found),
        _assemble_tasks($tasks), _assemble_variants(@task_names),
    );
}

sub ignore { return { ignore => [@_] } }

sub post {
    return { name => 'post', commands => _func_hash_list(@_) };
}

sub pre {
    return { name => 'pre', commands => _func_hash_list(@_) };
}

sub task {
    my ( $name, $commands, %opts ) = @_;
    die "No commands for $name" unless $commands;
    my $task = _hashify( name => $name, commands => _func_hash_list(@$commands) );
    my $deps = $opts{depends_on};
    if ( defined $deps ) {
        $task->{depends_on} =
          ref $deps eq 'ARRAY' ? _name_hash_list(@$deps) : _name_hash_list($deps);
    }
    return $task;
}

sub timeout {
    my $timeout = shift;
    return () unless $timeout;

    my @parts = (
        { exec_timeout_secs => $timeout },
        {
            timeout => [ _hashify( command => 'shell.exec', params => { script => 'ls -la' } ) ]
        },
    );

    return @parts;
}

# Private functions

sub _assemble_functions {
    return join "\n", "functions:", map { $functions{$_} } uniq sort @_;
}

sub _assemble_tasks {
    my $tasks = shift;
    my ( @parts, $pre, $post );
    for my $t (@$tasks) {
        if ( $t->{name} eq 'pre' ) {
            $pre = $t->{commands};
        }
        elsif ( $t->{name} eq 'post' ) {
            $post = $t->{commands};
        }
        else {
            push @parts, $t;
        }
    }
    return (
        ( $pre  ? ( { pre  => $pre } )  : () ),
        ( $post ? ( { post => $post } ) : () ),
        { tasks => [@parts] }
    );
}

sub _assemble_variants {
    my (@task_names) = @_;

    my @variants;
    for my $os ( sort keys %os_map ) {
        my $os_map = $os_map{$os};
        for my $ver ( @{ $os_map{$os}{perls} } ) {
            # OS specific path to a perl version's PREFIX
            my $prefix_path = "$os_map{$os}{perlroot}/$ver";

            # Paths below the prefix to add to PATH
            my @extra_paths = ( $os_map{$os}{perlpath} );
            push @extra_paths, $os_map{$os}{ccpath} if $os_map{$os}{ccpath};

            # Explicit path to perl to avoid confusion
            my $perlpath = "$prefix_path/$os_map{$os}{perlpath}/perl";

            push @variants,
              _hashify(
                name         => "os_${os}_perl_${ver}",
                display_name => "$os_map{$os}{name} Perl $ver",
                expansions   => {
                    os       => $os,
                    perlver  => $ver,
                    perlpath => $perlpath,
                    addpaths => join( ":", map { "$prefix_path/$_" } @extra_paths ),
                },
                run_on => [ @{ $os_map{$os}{run_on} } ],
                tasks  => [ @task_names ],
              );
        }
    }
    return { buildvariants => \@variants };
}

sub _default_headers {
    return { stepback => 'true' }, { command_type => 'system' };
}

sub _func_hash_list {
    return [ map { { func => $_ } } @_ ];
}

sub _hashify {
    tie my %hash, "Tie::IxHash", @_;
    return \%hash;
}

sub _name_hash_list {
    return [ map { { name => $_ } } @_ ];
}

sub _yaml_snippet {
    my $data = shift;

    # Passthrough literal text
    return $data unless ref $data;

    # Convert refs to YAML strings; upgrade 'true' or "true" to true, etc.
    my $yaml = CPAN::Meta::YAML->new($data);
    my $text = eval { $yaml->write_string };
    $text =~ s/[^\n]*\n//m;
    $text =~ s/((["'])true\2)/true/msg;
    $text =~ s/((["'])false\2)/false/msg;
    return $text;
}

1;

# Evergreen functions in YAML format. This is a cross-project pool
# of functions that can be included in tasks.
__DATA__
"fetchSource" :
  command: git.get_project
  params:
    directory: mongo-perl-bson
"dynamicVars":
  - command: shell.exec
    params:
      script: |
          set -o errexit
          set -o xtrace
          cat <<EOT > expansion.yml
          prepare_shell: |
              export PATH="${addpaths}:$PATH"
              export PERL="${perlpath}"
              export REPO_DIR="${repo_directory}"
              set -o errexit
              set -o xtrace
          EOT
          cat expansion.yml
  - command: expansions.update
    params:
      file: expansion.yml
"downloadPerl5Lib" :
  command: shell.exec
  params:
    script: |
      ${prepare_shell}
      curl https://s3.amazonaws.com/mciuploads/${aws_toolchain_prefix}/${os}/${perlver}/perl5lib.tar.gz -o perl5lib.tar.gz --fail --show-error --silent --max-time 240
      tar -zxf perl5lib.tar.gz
"uploadBuildArtifacts":
  - command: s3.put
    params:
      aws_key: ${aws_key}
      aws_secret: ${aws_secret}
      local_file: ${repo_directory}/build.tar.gz
      remote_file: ${aws_artifact_prefix}/${repo_directory}/${build_id}/build.tar.gz
      bucket: mciuploads
      permissions: public-read
      content_type: application/x-gzip
"downloadBuildArtifacts" :
  command: shell.exec
  params:
    script: |
      ${prepare_shell}
      cd ${repo_directory}
      curl https://s3.amazonaws.com/mciuploads/${aws_artifact_prefix}/${repo_directory}/${build_id}/build.tar.gz -o build.tar.gz --fail --show-error --silent --max-time 240
      tar -zxmf build.tar.gz
"whichPerl":
  command: shell.exec
  type: test
  params:
    script: |
      ${prepare_shell}
      $PERL -v
"buildModule" :
  command: shell.exec
  type: test
  params:
    script: |
      ${prepare_shell}
      $PERL ${repo_directory}/.evergreen/testing/build.pl
"testModule" :
  command: shell.exec
  type: test
  params:
    script: |
      ${prepare_shell}
      $PERL ${repo_directory}/.evergreen/testing/test.pl
"cleanUp":
  command: shell.exec
  params:
    script: |
      ${prepare_shell}
      rm -rf perl5
      rm -rf ${repo_directory}
