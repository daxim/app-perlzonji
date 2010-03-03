package App::perlzonji;
use 5.008;
use strict;
use warnings;
use File::BaseDir qw(xdg_cache_home);
use File::Next qw();
use File::Slurp qw(read_file);
use KinoSearch::Analysis::PolyAnalyzer qw();
use KinoSearch::InvIndexer qw();
use KinoSearch::Searcher qw();
use Path::Class qw(dir);
our $VERSION = '0.03';

# indexing peculiarities cribbed from Pod::POM::Web::Indexer
sub build_search_index {
    my ($index_directory) = @_;
    $index_directory ||= dir(xdg_cache_home, qw(kinosearch perlpod));

    my $invindexer = KinoSearch::InvIndexer->new(
        invindex => $index_directory,
        create   => 1,
        analyzer => KinoSearch::Analysis::PolyAnalyzer->new(language => 'en'),
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

    my $top_hit = KinoSearch::Searcher->new(
        invindex => dir(xdg_cache_home, 'kinosearch', 'perlpod'),
        analyzer => KinoSearch::Analysis::PolyAnalyzer->new(language => 'en'),
    )->search(query => $search_term)->fetch_hit->get_field_values->{title};
    $top_hit =~ s{\s .* \z}{}msx; # truncate at first space, leave name at front
    return $top_hit;
}

1;
__END__

=for stopwords Dieckow

=head1 NAME

App::perlzonji - a more knowledgeable perldoc

=head1 SYNOPSIS

    # perlzonji UNIVERSAL::isa
    # (runs `perldoc perlobj`)

=head1 DESCRIPTION

Helper routines for C<perlzonji>.

=head1 INTERFACE

=head2 C<build_search_index>

    build_search_index($index_directory)

Creates a L<KinoSearch> full-text index. This typically takes about 3 minutes
and 180 MiB.

Takes an optional directory name where to store the index files. Default is
F<kinosearch/perlpod/> in the XDG cache home directory.

=head2 C<module_name_from_query>

    module_name_from_query($search_term, $index_directory)

Returns a module name that is the top result for a search in the full-text
index.

Takes a mandatory query string. Takes an optional directory name for the index
files as above.

=head1 BUGS AND LIMITATIONS

No bugs have been reported.

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org>.

=head1 INSTALLATION

See perlmodinstall for information and options on installing Perl modules.

=head1 AVAILABILITY

The latest version of this module is available from the Comprehensive Perl
Archive Network (CPAN). Visit L<http://www.perl.com/CPAN/> to find a CPAN
site near you. Or see L<http://search.cpan.org/dist/App-perlzonji/>.

The development version lives at L<http://github.com/hanekomu/app-perlzonji/>.
Instead of sending patches, please fork this project using the standard git
and github infrastructure.

=head1 AUTHORS

Marcel GrE<uuml>nauer, C<< <marcel@cpan.org> >>

Lars Dieckow, C<< <daxim@cpan.org> >>

=head1 COPYRIGHT AND LICENSE

Copyright 2010 by Marcel GrE<uuml>nauer

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
