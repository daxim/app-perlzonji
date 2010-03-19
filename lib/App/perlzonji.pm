use 5.008;
use strict;
use warnings;

package App::perlzonji;

# ABSTRACT: a more knowledgeable perldoc
use File::BaseDir qw(xdg_cache_home);
use File::Next qw();
use File::Path qw(make_path);
use File::Slurp qw(read_file);
use KinoSearch1::Analysis::PolyAnalyzer qw();
use KinoSearch1::InvIndexer qw();
use KinoSearch1::Searcher qw();
use Path::Class qw(dir);
use Pod::Usage::CommandLine qw(GetOptions pod2usage);

# Specify like this because it's easier. We compute the reverse later (i.e.,
# it should be easier on the hacker than on the computer).
#
# Note: 'for' is a keyword for perlpod as well ('=for'), but is listed for
# perlsyn here, as that's more likely to be the intended meaning.
our %found_in = (
    perlop => [
        qw(lt gt le ge eq ne cmp not and or xor s m tr y
          q qq qr qx qw)
    ],
    perlsyn => [qw(if else elsif unless while until for foreach)],
    perlobj => [qw(isa ISA can VERSION)],
    perlsub => [qw(AUTOLOAD BEGIN CHECK INIT END DESTROY)],
    perltie => [
        qw(TIESCALAR TIEARRAY TIEHASH TIEHANDLE FETCH STORE UNTIE
          FETCHSIZE STORESIZE POP PUSH SHIFT UNSHIFT SPLICE DELETE EXISTS
          EXTEND CLEAR FIRSTKEY NEXTKEY WRITE PRINT PRINTF READ READLINE GETC
          CLOSE)
    ],
    perlvar => [
        qw(_ a b 0 1 2 3 4 5 6 7 8 9 ARG STDIN STDOUT STDERR ARGV ENV PREMATCH
          MATCH POSTMATCH LAST_PAREN_MATCH LAST_SUBMATCH_RESULT
          LAST_MATCH_END MULTILINE_MATCHING INPUT_LINE_NUMBER NR
          INPUT_RECORD_SEPARATOR RS OUTPUT_AUTOFLUSH OUTPUT_FIELD_SEPARATOR
          OFS OUTPUT_RECORD_SEPARATOR ORS LIST_SEPARATOR SUBSCRIPT_SEPARATOR
          SUBSEP FORMAT_PAGE_NUMBER FORMAT_LINES_PER_PAGE FORMAT_LINES_LEFT
          LAST_MATCH_START FORMAT_NAME FORMAT_TOP_NAME
          FORMAT_LINE_BREAK_CHARACTERS FORMAT_FORMFEED ACCUMULATOR
          CHILD_ERROR CHILD_ERROR_NATIVE ENCODING OS_ERROR ERRNO
          EXTENDED_OS_ERROR EVAL_ERROR PROCESS_ID PID REAL_USER_ID UID
          EFFECTIVE_USER_ID EUID REAL_GROUP_ID GID EFFECTIVE_GROUP_ID EGID
          PROGRAM_NAME COMPILING DEBUGGING RE_DEBUG_FLAGS RE_TRIE_MAXBUF
          SYSTEM_FD_MAX INPLACE_EDIT OSNAME OPEN PERLDB
          LAST_REGEXP_CODE_RESULT EXCEPTIONS_BEING_CAUGHT BASETIME TAINT
          UNICODE UTF8CACHE UTF8LOCALE PERL_VERSION WARNING WARNING_BITS
          WIN32_SLOPPY_STAT EXECUTABLE_NAME ARGVOUT INC SIG __DIE__ __WARN__
          $& $` $' $+ $^N @+ %+ $. $/ $| $\ $" $; $% $= $- @- %- $~ $^ $:
          $? $! %! $@ $$ $< $> $[ $] $^A $^C $^D $^E $^F $^H $^I $^L
          $^M $^O $^P $^R $^S $^T $^V $^W $^X %^H @F @_
          ), '$,', '$(', '$)',
    ],
    perlrun => [
        qw(HOME LOGDIR PATH PERL5LIB PERL5OPT PERLIO PERLIO_DEBUG PERLLIB
          PERL5DB PERL5DB_THREADED PERL5SHELL PERL_ALLOW_NON_IFS_LSP
          PERL_DEBUG_MSTATS PERL_DESTRUCT_LEVEL PERL_DL_NONLAZY PERL_ENCODING
          PERL_HASH_SEED PERL_HASH_SEED_DEBUG PERL_ROOT PERL_SIGNALS
          PERL_UNICODE)
    ],
    perlpod => [
        qw(head1 head2 head3 head4 over item back cut pod begin
          end)
    ],
    perldata => [qw(__FILE__ __LINE__ __PACKAGE__)],

    # We could also list common functions and methods provided by some
    # commonly used modules, like:
    Moose => [
        qw(has before after around super override inner augment confessed
          extends with)
    ],
    Error        => [qw(try catch except otherwise finally record)],
    SelfLoader   => [qw(__DATA__ __END__ DATA)],
    Storable     => [qw(freeze thaw)],
    Carp         => [qw(carp cluck croak confess shortmess longmess)],
    'Test::More' => [
        qw(plan use_ok require_ok ok is isnt like unlike cmp_ok
          is_deeply diag can_ok isa_ok pass fail eq_array eq_hash eq_set skip
          todo_skip builder SKIP: TODO:)
    ],
    'Getopt::Long' => [qw(GetOptions)],
    'File::Find'   => [qw(find finddepth)],
    'File::Path'   => [qw(mkpath rmtree)],
    'File::Spec'   => [
        qw(canonpath catdir catfile curdir devnull rootdir
          tmpdir updir no_upwards case_tolerant file_name_is_absolute path
          splitpath splitdir catpath abs2rel rel2abs)
    ],
    'File::Basename' => [
        qw(fileparse fileparse_set_fstype basename
          dirname)
    ],
    'File::Temp' => [
        qw(tempfile tempdir tmpnam tmpfile mkstemp mkstemps
          mkdtemp mktemp unlink0 safe_level)
    ],
    'File::Copy' => [qw(copy move cp mv rmscopy)],
    'PerlIO' =>
      [qw(:bytes :crlf :mmap :perlio :pop :raw :stdio :unix :utf8 :win32)],
);

our %opt = ('perldoc-command' => 'perldoc');

sub run {
    GetOptions(\%opt, 'perldoc-command:s', 'debug', 'build-search-index:s') or pod2usage(2);
    if (exists $opt{'build-search-index'}) {
        build_search_index($opt{'build-search-index'});
        exit;
    }

    my $word = shift @ARGV;
    while (my ($file, $words) = each our %found_in) {
        $_ eq $word && execute($opt{'perldoc-command'} => $file) for @$words;
    }

    # Is it a label (ends with ':')? Do this after %found_in, because there are
    # special labels such as 'SKIP:' and 'TODO:' that map to Test::More
    $word =~ /^\w+:$/       && execute($opt{'perldoc-command'} => 'perlsyn');
    $word =~ /^UNIVERSAL::/ && execute($opt{'perldoc-command'} => 'perlobj');
    $word =~ /^CORE::/      && execute($opt{'perldoc-command'} => 'perlsub');

    # try it as a module
    try_module($word);

    # if it contains '::', it's not a function - strip off the last bit and try
    # that again as a module
    $word =~ s/::(\w+)$// && try_module($word);

    # assume it's a function
    exit if 0 == subprocess($opt{'perldoc-command'}, qw(-f), $word);

    # perldoc failed, full text search as last resort
    try_module(module_name_from_query($word));

    exit;
}

# if we can require() it, we run perldoc for the module
sub try_module {
    my $module = shift;
    eval "use $module;";
    !$@ && execute($opt{'perldoc-command'} => $module);
}

sub execute {
    print "@_\n" if $opt{debug};
    exec @_;
}

# 'run' already taken, quelle surprise
sub subprocess {
    print "@_\n" if $opt{debug};
    return system @_;
}

# indexing peculiarities cribbed from Pod::POM::Web::Indexer
sub build_search_index {
    my ($index_directory) = @_;
    $index_directory ||= dir(xdg_cache_home, qw(kinosearch perlpod))->stringify;
    make_path($index_directory);

    my $invindexer = KinoSearch1::InvIndexer->new(
        invindex => $index_directory,
        create   => 1,
        analyzer => KinoSearch1::Analysis::PolyAnalyzer->new(language => 'en'),
    );
    $invindexer->spec_field(
        name  => 'title',
        boost => 3,
    );
    $invindexer->spec_field(name => 'bodytext');

    my $ignore_dirs = qr[auto | unicore | DateTime/TimeZone | DateTime/Locale]x;
    my $files = File::Next::files({
        file_filter => sub {
            /\. (pm|pod) \z/msx && $File::Next::dir !~ /$ignore_dirs/ && -s ($File::Next::name) < 300_000;
        },
        sort_files => 1,
    }, grep { '.' ne $_ } @INC);

    my $ignore_headings = qr[
          SYNOPSIS | DESCRIPTION | METHODS   | FUNCTIONS |
          BUGS     | AUTHOR      | SEE\ ALSO | COPYRIGHT | LICENSE ]x;
    my %seen;
    while (defined(my $file = $files->())) {
        next if exists $seen{$file};    # skip dupes
        $seen{$file} = undef;

        print "$file\n" if $opt{debug};
        my $document = read_file $file;
        my ($title) = ($document =~ /^=head1\s*NAME\s*(.*)$/m);
        $title ||= '';
        $title    =~ s/\t/ /g;
        $document =~ s/^=head1\s+($ignore_headings).*$//m;    # remove full line of those
        $document =~ s/^=(head\d|item)//mg;                   # just remove command of =head* or =item
        $document =~ s/^=\w.*//mg;                            # remove full line of all other commands

        my $kino = $invindexer->new_doc;
        $kino->set_value(title    => $title);
        $kino->set_value(bodytext => $document);
        $invindexer->add_doc($kino);
    }

    $invindexer->finish;
    return;
}

sub module_name_from_query {
    my ($search_term, $index_directory) = @_;
    $index_directory ||= dir(xdg_cache_home, qw(kinosearch perlpod));

    my $top_hit = KinoSearch1::Searcher->new(
        invindex => $index_directory,
        analyzer => KinoSearch1::Analysis::PolyAnalyzer->new(language => 'en'),
    )->search(query => $search_term)->fetch_hit->get_field_values->{title};
    $top_hit =~ s{\s .* \z}{}msx; # truncate at first space, leave name at front
    return $top_hit;
}

1;

=begin :prelude

=for stopwords Dieckow gozonji desu ka

=end :prelude

=head1 SYNOPSIS

    # perlzonji UNIVERSAL::isa
    # (runs `perldoc perlobj`)

=head1 DESCRIPTION

C<perlzonji> is like C<perldoc> except it knows about more things. Try these:

    perlzonji xor
    perlzonji foreach
    perlzonji isa
    perlzonji AUTOLOAD
    perlzonji TIEARRAY
    perlzonji INPUT_RECORD_SEPARATOR
    perlzonji '$^F'
    perlzonji PERL5OPT
    perlzonji :mmap
    perlzonji __WARN__
    perlzonji __PACKAGE__
    perlzonji head4

For efficiency, C<alias pod=perlzonji>.

The word C<zonji> means "knowledge of" in Japanese. Another example is the
question "gozonji desu ka", meaning "Do you know?" - "go" is a prefix added
for politeness.

=head1 OPTIONS

Options can be shortened according to L<Getopt::Long/"Case and abbreviations">.

=over

=item C<--perldoc-command>

Specifies the POD formatter/pager to delegate to. Default is C<perldoc>.
C<annopod> from L<AnnoCPAN::Perldoc> is a better alternative.

=item C<--build-search-index>

See L</"build_search_index">. Takes an optional directory name.

=item C<--debug>

Prints the whole command before executing it.

=item C<--help>

Prints a brief help message and exits.

=item C<--man>

Prints the manual page and exits.

=back

=function run

The main function, which is called by the C<perlzonji> program.

=function try_module

Takes as argument the name of a module, tries to load that module and executes
the formatter, giving that module as an argument. If loading the module fails,
this subroutine does nothing.

=function execute

Executes the given command using C<exec()>. In debug mode, it also prints the
command before executing it.

=function subprocess

Runs and returns from the given command using C<system()>. In debug mode, it
also prints the command before running it.

=function build_search_index

    build_search_index($index_directory)

Creates a L<KinoSearch1> full-text index. This typically takes about 3 minutes
and 180 MiB.

Takes an optional directory name where to store the index files. Default is
F<kinosearch/perlpod/> in the XDG cache home directory.

=function module_name_from_query

    module_name_from_query($search_term, $index_directory)

Returns a module name that is the top result for a search in the full-text
index.

Takes a mandatory query string. Takes an optional directory name for the index
files as above.
