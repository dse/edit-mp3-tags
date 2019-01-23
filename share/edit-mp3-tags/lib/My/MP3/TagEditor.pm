package My::MP3::TagEditor;
use warnings;
use strict;
use v5.10.0;

use MP3::Tag;
use File::Temp qw(tempfile);
use Data::Dumper;
use Text::ParseWords;
use Text::Trim;
use File::Which;
use List::Util qw(max min uniq all none);
use File::Basename qw(dirname basename);
use POSIX qw(floor);
use Sort::Naturally qw(nsort ncmp);

use Moo;

has dryRun                 => (is => 'rw', default => 0);
has editedTracksByFilename => (is => 'rw', default => sub { return {}; });
has editedTracks           => (is => 'rw', default => sub { return []; });
has force                  => (is => 'rw', default => 0);
has modified               => (is => 'rw', default => 0);
has parseFilenames         => (is => 'rw', default => 0);
has tempnameMtime          => (is => 'rw');
has tempname               => (is => 'rw');
has tracksByFilename       => (is => 'rw', default => sub { return {}; });
has tracks                 => (is => 'rw', default => sub { return []; });
has verbose                => (is => 'rw', default => 0);
has forceFixTrackNumbers   => (is => 'rw', default => 0);

use lib "$ENV{HOME}/git/dse.d/music-scripts/lib";
use My::Music::Util;

sub run {
    my ($self, @args) = @_;
    my @filenames = My::Music::Util->findSongs(filenames => \@args);
    $self->loadTagsFromFiles(@filenames);
    $self->fixTrackNumbers($self->tracks);
    $self->sortTracks($self->tracks);
    $self->createTagsFileToEdit();
    $self->editTagsFile();
    $self->loadTagsFromTagsFile();
    $self->fixTrackNumbers($self->editedTracks);
    if ($self->modified || $self->dryRun || $self->force) {
        $self->saveTags();
    }
}

our $RX_INTEGER_OF_INTEGER;
our $RX_INTEGER;
BEGIN {
    $RX_INTEGER_OF_INTEGER = qr{(?: \s* (\d+) \s* (?:/|of) \s* (\d+) \s* )}xi;
    $RX_INTEGER            = qr{(?: \s* (\d+) \s*                        )}xi;
}

sub hasMultipleDirectories {
    my ($self) = @_;
    my @dirname = map { $_->{dirname} } @{$self->tracks};
    my %dirname = map { ($_, 1) } @dirname;
    my $hasMultipleDirectories = (scalar keys %dirname) != 1;
    return $hasMultipleDirectories;
}

sub fixTrackNumbers {
    my ($self, $allTracksArray) = @_;

    my %trackArrayByDirname = ();
    foreach my $trackHash (@{$allTracksArray}) {
        my $dirname = $trackHash->{dirname};
        push(@{$trackArrayByDirname{$dirname}}, $trackHash);
    }

    $self->extractDiscNumbersFromTags(@$allTracksArray);
    $self->extractTrackNumbersFromTags(@$allTracksArray);

    foreach my $trackHash (@$allTracksArray) {
        $trackHash->{oldTrack} = $trackHash->{track};
        $trackHash->{oldDisc}  = $trackHash->{disc};
    }

    foreach my $dirname (sort keys %trackArrayByDirname) {
        my $trackArray = $trackArrayByDirname{$dirname};

        if (!$self->noTracksHaveTrackNumbers(@$trackArray) || $self->forceFixTrackNumbers) {
            $self->extractTrackNumbersFromFilenames(@$trackArray);
        }

        if ($self->trackNumbersAreFromMultiDiscSet(@$trackArray) || $self->forceFixTrackNumbers) {
            $self->fixMultiDiscSetTrackNumbers(@$trackArray);
        }

        my %tracksByDiscNo;

        foreach my $trackHash (@$trackArray) {
            my $discNo = $trackHash->{discNo} || 1;
            push(@{$tracksByDiscNo{$discNo}}, $trackHash);
        }

        if ($self->tracksAreFromMultipleDiscs(@$trackArray)) {
            # Make sure all tracks have disc numbers.
            foreach my $trackHash (@$trackArray) {
                $trackHash->{discNo} ||= 1;
            }

            # Make sure all tracks have number of discs specified, if
            # appropriate.
            my $numberOfDiscs = scalar keys %tracksByDiscNo;
            my $sortedDiscNumbers = join(',', sort { $a <=> $b } keys %tracksByDiscNo);
            my $checkDiscNumbers  = join(',', 1 .. $numberOfDiscs);
            if ($sortedDiscNumbers eq $checkDiscNumbers) {
                foreach my $trackHash (@$trackArray) {
                    $trackHash->{discOf} = $numberOfDiscs;
                }
            }
        }

        foreach my $discNo (sort { $a <=> $b } keys %tracksByDiscNo) {
            # Make sure all tracks for each disc have number of tracks
            # specified, if appropriate.
            my @discTrackArray = @{$tracksByDiscNo{$discNo}};
            my $numberOfTracks = scalar @discTrackArray;
            my $sortedTrackNumbers = join(",", sort { $a <=> $b } map { $_->{trackNo} || 0 } @discTrackArray);
            my $checkTrackNumbers  = join(",", 1 .. $numberOfTracks);
            if ($sortedTrackNumbers eq $checkTrackNumbers) {
                foreach my $trackHash (@discTrackArray) {
                    $trackHash->{trackOf} = $numberOfTracks;
                }
            }
        }
    }

    foreach my $trackHash (@$allTracksArray) {
        if ($trackHash->{discNo}) {
            if ($trackHash->{discOf}) {
                $trackHash->{disc} = sprintf('%d/%d', $trackHash->{discNo}, $trackHash->{discOf});
            } else {
                $trackHash->{disc} = sprintf('%d', $trackHash->{discNo});
            }
        } else {
            $trackHash->{disc} = '';
        }
        if ($trackHash->{trackNo}) {
            if ($trackHash->{trackOf}) {
                $trackHash->{track} = sprintf('%d/%d', $trackHash->{trackNo}, $trackHash->{trackOf});
            } else {
                $trackHash->{track} = sprintf('%d', $trackHash->{trackNo});
            }
        } else {
            $trackHash->{track} = '';
        }
        if ((($trackHash->{track} // '') ne ($trackHash->{oldTrack} // '')) || (($trackHash->{disc} // '') ne ($trackHash->{oldDisc} // ''))) {
            $trackHash->{modified} = 1;
        }
    }

    if (grep { $_->{modified} } @$allTracksArray) {
        $self->modified(1);
    }
}

sub findTrackNumbersInFilenames {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    return unless scalar @trackArray >= 2;
    my $prefix = $self->findCommonPrefix(map { $_->{basename} } @trackArray);
    return if length $prefix <= 0;
    my @theRest = map { substr($_->{basename}, length $prefix) } @trackArray;
    my @trackNumbers = $self->getTrackNumbersIfAll(@theRest);
    return @trackNumbers;
}

sub findCommonPrefix {
    my ($self, @strings) = @_;
    return unless scalar @strings;
    my $minLength = min map { length $_ } @strings;
    return if $minLength < 1;
    my $result = '';
    for (my $length = 1; $length <= $minLength; $length += 1) {
        my @substrings = map { substr($_, 0, $length) } @strings;
        my @uniq = uniq sort @substrings;
        last if (scalar @uniq != 1);
        ($result) = @uniq;
    }
    return $result;
}

sub getTrackNumbersIfAll {
    my ($self, @strings) = @_;
    return unless scalar @strings;
    my @numbers = map { $_ =~ m{^\d+} ? ($& + 0) : undef } @strings;
    return @numbers if !grep { !defined $_ } @numbers;
    return;
}

sub loadTagsFromFiles {
    my ($self, @filenames) = @_;
    $self->tracks([]);
    $self->tracksByFilename({});
    my $origIndex = 0;
    foreach my $filename (@filenames) {
        $origIndex += 1;
        next unless $filename =~ m{\.mp3$}i;

        my $mp3 = MP3::Tag->new($filename);
        if (!defined $mp3) {
            warn("edit-mp3-tags: could not read tags for $filename\n");
            next;
        }
        $mp3->config("prohibit_v24" => 0);
        $mp3->config("write_v24" => 1);

        my $trackHash = $self->getTagsFromMP3Tag($mp3);
        $trackHash->{filename}  = $filename;
        $trackHash->{origIndex} = $origIndex;
        $trackHash->{dirname}   = dirname($filename);
        $trackHash->{basename}  = basename($filename);

        my @keys = keys %$trackHash;
        foreach my $key (@keys) {
            if (isBlank($trackHash->{$key})) {
                delete $trackHash->{$key};
            }
        }

        if ($self->parseFilenames) {
            if ($filename =~ m{^
                               (?:(\d+)(?:\s*-+\s*|\s*\.\s*|\s+))?
                               (.*?)
                               (?:\s*-+\s*)
                               (.*?)
                               (?:\.mp3)?
                               $}xi) {
                my ($newTrack, $newArtist, $newTitle) = ($1, $2, $3);
                if (!isBlank($newTrack)) {
                    $trackHash->{track} = $newTrack;
                    $trackHash->{modified} = 1;
                    $self->modified(1);
                }
                if (!isBlank($newArtist)) {
                    $trackHash->{artist} = $newArtist;
                    $trackHash->{modified} = 1;
                    $self->modified(1);
                }
                if (!isBlank($newTitle)) {
                    $trackHash->{title} = $newTitle;
                    $trackHash->{modified} = 1;
                    $self->modified(1);
                }
            }
        }

        push(@{$self->tracks}, $trackHash);
        $self->tracksByFilename->{$filename} = $trackHash;
    }
}

sub sortTracks {
    my ($self, $array) = @_;
    @$array = sort {
        ncmp(lc($a->{dirname}), lc($b->{dirname})) ||
            (($a->{discNo} || 1) <=> ($b->{discNo} || 1)) ||
            (($a->{trackNo} || 0) <=> ($b->{trackNo} || 0)) ||
            ncmp(lc($a->{basename}), lc($b->{basename}))
    } @$array;
}

sub createTagsFileToEdit {
    my ($self, @filenames) = @_;
    if (scalar @{$self->tracks}) {
        my ($fh, $tempname) = tempfile();
        $self->tempname($tempname);

        my $hasMultipleDirectories = $self->hasMultipleDirectories;

        print $fh <<"EOF" if !$hasMultipleDirectories;
# Lines starting with '#' are ignored.

# Un-comment and edit any of the following line(s) for albums.
#albumArtist=Various Artists
#artist=<artist>
#album=<album>
#year=<year>

# For multi-disc sets, prefix each line with:       1/2:   (optional)
# Then if you need to fix track numbers manually:   1/10.

# Make changes, save, and exit your editor to effect your changes.
# Blank out this file to cancel all changes.

EOF
        print $fh <<"EOF" if $hasMultipleDirectories;
# Lines starting with '#' are ignored.

# Un-comment and edit lines like the following for albums.
#     #albumArtist=Various Artists
#     #artist=<artist>
#     #album=<album>
#     #year=<year>

# For multi-disc sets, prefix each line with:       1/2:   (optional)
# Then if you need to fix track numbers manually:   1/10.

# Make changes, save, and exit your editor to effect your changes.
# Blank out this file to cancel all changes.

EOF

        my @dirname = map { $_->{dirname} } @{$self->tracks};
        my %dirname = map { ($_, 1) } @dirname;
        @dirname = sort keys %dirname;

        foreach my $dirname (@dirname) {
            my @trackArray = grep { $_->{dirname} eq $dirname } @{$self->tracks};

            my $showTpos = grep { !isBlank($_->{tpos}) } @trackArray;
            my %columnWidths = ();
            foreach my $column (qw(artist title album year albumArtist)) {
                my @lengths = map { length($_) } grep { defined $_ } map { $_->{$column} } @trackArray;
                if (scalar @lengths) {
                    $columnWidths{$column} = max @lengths;
                } else {
                    $columnWidths{$column} = 0;
                }
            }
            my $extraSpace = 2;

            if ($hasMultipleDirectories) {

                my @artist      = uniq sort grep { defined $_ && $_ ne '' } map { $_->{artist}      } @trackArray; # keep to be on the safe side
                my @albumArtist = uniq sort grep { defined $_ && $_ ne '' } map { $_->{albumArtist} } @trackArray;
                my @album       = uniq sort grep { defined $_ && $_ ne '' } map { $_->{album}       } @trackArray;
                my @year        = uniq sort grep { defined $_ && $_ ne '' } map { $_->{year}        } @trackArray;

                # show
                my $albumArtist = (scalar @albumArtist == 1) ? $albumArtist[0] : '<albumArtist>'; # keep to be on the safe side
                my $artist      = (scalar @artist      == 1) ? $artist[0]      : '';
                my $album       = (scalar @album       == 1) ? $album[0]       : '';
                my $year        = (scalar @year        == 1) ? $year[0]        : '';

                if (($artist // '') !~ m{\S}) {
                    $artist = '<artist>';
                }
                if (($album // '') !~ m{\S}) {
                    $album = '<album>';
                }
                if (($year // '') !~ m{\S}) {
                    $year = '<year>';
                }

                print $fh "\n";
                print $fh "[album $dirname]\n";
                print $fh "#albumArtist=Various Artists\n";
                print $fh "#artist=$artist\n";
                print $fh "#album=$album\n";
                print $fh "#year=$year\n";
                print $fh "\n";
            }

            foreach my $trackHash (@trackArray) {
                printf $fh ("%7s: ",             $trackHash->{tpos} // "") if $showTpos;
                printf $fh ("%7s. ",             $trackHash->{track} // "");
                printf $fh ("artist=%-*s",       $extraSpace + $columnWidths{artist},      $trackHash->{artist}      // "");
                printf $fh ("|title=%-*s",       $extraSpace + $columnWidths{title},       $trackHash->{title}       // "");
                printf $fh ("|album=%-*s",       $extraSpace + $columnWidths{album},       $trackHash->{album}       // "");
                printf $fh ("|year=%-*s",        $extraSpace + $columnWidths{year},        $trackHash->{year}        // "");
                printf $fh ("|albumArtist=%-*s", $extraSpace + $columnWidths{albumArtist}, $trackHash->{albumArtist} // "");
                printf $fh ("|filename=%s",      $trackHash->{filename} // "");
                print  $fh "\n";
            }
        }

        $self->tempnameMtime((stat($tempname))[9]);
    } else {
        warn("No tracks.  Exiting.\n");
        exit(0);
    }
}

sub editTagsFile {
    my ($self) = @_;
    my $editor = $ENV{VISUAL} // $ENV{EDITOR} //
        which('nano') // which('pico') // which('vi');
    if (!$editor) {
        die("Can't figure out what editor you want to use.\n".
                "You don't have VISUAL or EDITOR specified and\n".
                "you don't have nano, pico, or vi.\n");
    }
    my @editor = shellwords($editor);
    my $result = system(@editor, $self->tempname);
    my $mtime = (stat($self->tempname))[9];
    if ($result) {
        $self->editorFailed();
    } else {
        if ($mtime != $self->tempnameMtime) {
            $self->modified(1);
        }
    }
    if (!$self->modified) {
        if (!$self->force && !$self->dryRun) {
            $self->notModified();
        }
    }
}

sub editorFailed {
    my ($self) = @_;
    warn("Editor failed.  Exiting.\n");
    unlink($self->tempname);
    exit(1);
}

sub notModified {
    my ($self) = @_;
    warn("Not modified.  Exiting.\n");
    unlink($self->tempname);
    exit(0);
}

sub loadTagsFromTagsFile {
    my ($self) = @_;
    my $tempname = $self->tempname;
    my $fh;
    open($fh, "<", $tempname) or die("Cannot read $tempname: $!\n");
    my $album = {};
    my $lastLineAlbum = 0;
    my $lastLineTrack = 0;
    $self->editedTracks([]);
    $self->editedTracksByFilename({});
    local $. = 0;
    while (<$fh>) {
        next if m{^\s*\#};      # ignore comments;
        s{\R\z}{};              # safer chomp
        next unless m{\S};      # skip blank lines

        if (m{^\s*\[\s*album\s*]\s*$}i) {
            $album = {};
            $lastLineAlbum = 1;
            $lastLineTrack = 0;
            next;
        }

        if (!m{\|}) {
            if (!$lastLineAlbum) {
                $album = {};
            }
            s{^\s+}{};
            s{\s+$}{};
            if (m{\s*=\s*}) {
                my ($key, $value) = ($`, $');
                $key =~ s{-+}{_}g;
                if (isBlank($value)) {
                    delete $album->{$key};
                } else {
                    $album->{$key} = $value;
                }
            } else {
                s{-+}{_}g;
                $album->{$_} = 1;
            }
            $lastLineAlbum = 1;
            $lastLineTrack = 0;
            next;
        }

        my $trackHash = {};

        if (s{^ ($RX_INTEGER_OF_INTEGER|$RX_INTEGER) \: \s* }{}x) {
            $trackHash->{tpos} = $1;
        }
        if (s{^ ($RX_INTEGER_OF_INTEGER|$RX_INTEGER) \. \s* }{}x) {
            $trackHash->{track} = $1;
        }

        my @kv = split(/\|/, $_);
        foreach (@kv) {
            s{^\s+}{};
            s{\s+$}{};
            if (m{\s*=\s*}) {
                my ($key, $value) = ($`, $');
                if (isBlank($value)) {
                    delete $trackHash->{$key};
                } else {
                    $trackHash->{$key} = $value;
                }
            } else {
                $trackHash->{$_} = 1;
            }
        }

        foreach my $k (keys %$album) {
            $trackHash->{$k} = $album->{$k};
        }

        my $filename = $trackHash->{filename};
        $trackHash->{dirname}  = dirname($filename)  if defined $filename;
        $trackHash->{basename} = basename($filename) if defined $filename;

        push(@{$self->editedTracks}, $trackHash);
        $self->editedTracksByFilename->{$trackHash->{filename}} = $trackHash;
        if ($self->verbose >= 3) {
            say STDERR Dumper($trackHash);
        }

        $lastLineAlbum = 0;
        $lastLineTrack = 1;
    }
}

sub saveTags {
    my ($self) = @_;

    foreach my $trackHash (@{$self->editedTracks}) {
        my $filename = $trackHash->{filename};
        if (isBlank($filename)) {
            warn("No filename on $filename line $.\n");
            next;
        }

        # my $track       = $trackHash->{track};
        # my $artist      = $trackHash->{artist};
        # my $title       = $trackHash->{title};
        # my $album       = $trackHash->{album};
        # my $year        = $trackHash->{year};
        # my $tpos        = $trackHash->{tpos};
        # my $albumArtist = $trackHash->{albumArtist};

        if ($self->verbose >= 2 || ($self->dryRun && $self->verbose)) {
            printf("%s\n", $filename);
            printf("  TRACK        = %s\n", $trackHash->{track}       // "");
            printf("  ARTIST       = %s\n", $trackHash->{artist}      // "");
            printf("  TITLE        = %s\n", $trackHash->{title}       // "");
            printf("  ALBUM        = %s\n", $trackHash->{album}       // "");
            printf("  YEAR         = %s\n", $trackHash->{year}        // "");
            printf("  TPOS (DISC)  = %s\n", $trackHash->{tpos}        // "");
            printf("  ALBUM_ARTIST = %s\n", $trackHash->{albumArtist} // "");
        }
        if ($self->dryRun) {
            next;
        }

        my $mp3 = MP3::Tag->new($filename);
        if (!defined $mp3) {
            warn("edit-mp3-tags: could not read tags for $filename\n");
            next;
        }
        $mp3->config("prohibit_v24" => 0);
        $mp3->config("write_v24" => 1);

        if (($trackHash->{albumArtist} // "") eq "Various Artists") {
            $trackHash->{tcmp} = 1;
        } else {
            $trackHash->{tcmp} = undef;
        }

        my $noChange = 1;
        my $oldTags = $self->getTagsFromMP3Tag($mp3);
        foreach my $key (keys %$oldTags) {
            if (($oldTags->{$key} // "") ne ($trackHash->{$key} // "")) {
                $noChange = 0;
                last;
            }
        }
        if ($noChange) {
            if ($self->verbose) {
                warn("No changes to tags in $filename\n");
            }
            next;
        }

        # second arg is force_id3v2
        $mp3->title_set($trackHash->{title} // "", 1);
        $mp3->artist_set($trackHash->{artist} // "", 1);
        $mp3->year_set($trackHash->{year} // "", 1);
        $mp3->album_set($trackHash->{album} // "", 1);
        $mp3->track_set($trackHash->{track} // "", 1);

        $mp3->select_id3v2_frame_by_descr("TPOS", $trackHash->{tpos} // "");
        $mp3->select_id3v2_frame_by_descr("TPE2", $trackHash->{albumArtist} // "");
        $mp3->select_id3v2_frame_by_descr("TCMP", $trackHash->{tcmp});

        if ($self->verbose) {
            warn("Updating tags on $filename\n");
        }
        $mp3->update_tags(undef, 1);
        if ($self->verbose) {
            warn("Done.\n");
        }
    }
}

sub getTagsFromMP3Tag {
    my ($self, $mp3) = @_;

    my @autoinfoFields = qw(title track artist album comment year genre);
    my @trimFields     = qw(title artist album albumArtist);

    my $tags = {};
    @{$tags}{@autoinfoFields} = $mp3->autoinfo();
    $tags->{albumArtist} = $mp3->select_id3v2_frame_by_descr("TPE2"); # "Band/orchestra/accompaniment"
    $tags->{tcmp}        = $mp3->select_id3v2_frame_by_descr("TCMP"); # iTunes Compilation Flag
    $tags->{tpos}        = $mp3->select_id3v2_frame_by_descr("TPOS"); # part of set (e.g., disc 1/2)

    foreach my $field (@trimFields) {
        $tags->{$field} = trim($tags->{$field}) if defined $tags->{$field};
    }

    return $tags;
}

sub isBlank {
    my ($string) = @_;
    return 1 if !defined $string;
    return 1 if $string !~ m{\S};
    return 0;
}

sub extractTrackNumbersFromTags {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    foreach my $trackHash (@trackArray) {
        my $track = $trackHash->{track};
        if (defined $track && $track =~ m{^ $RX_INTEGER_OF_INTEGER $}x) {
            $trackHash->{trackNo} = $1 + 0;
            $trackHash->{trackOf} = $2 + 0;
        } elsif (defined $track && $track =~ m{^ $RX_INTEGER $}x) {
            $trackHash->{trackNo} = $1 + 0;
            $trackHash->{trackOf} = undef;
        }
    }
}

sub extractDiscNumbersFromTags {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    foreach my $trackHash (@trackArray) {
        my $tpos = $trackHash->{tpos};
        if (defined $tpos && $tpos =~ m{^ $RX_INTEGER_OF_INTEGER $}x) {
            my ($discNo, $discOf) = ($1 + 0, $2 + 0);
            $trackHash->{discNo} = $discNo;
            $trackHash->{discOf} = $discOf;
        } elsif (defined $tpos && $tpos =~ m{^ $RX_INTEGER $}x) {
            my ($discNo) = ($1 + 0);
            $trackHash->{discNo} = $discNo;
            $trackHash->{discOf} = undef;
        }
    }
}

sub noTracksHaveTrackNumbers {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    return none { defined $_->{trackNo} } @trackArray;
}

sub allTracksHaveTrackNumbers {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    return all { defined $_->{trackNo} } @trackArray;
}

sub extractTrackNumbersFromFilenames {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    my @trackNumbers = $self->findTrackNumbersInFilenames(@trackArray);
    if (scalar @trackNumbers == scalar @trackArray) {
        for (my $i = 0; $i < scalar @trackNumbers; $i += 1) {
            $trackArray[$i]->{trackNo} = $trackNumbers[$i];
        }
    }
}

sub trackNumbersAreFromMultiDiscSet {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    return all {
        ($_->{discNo} && $_->{discNo} > 0) ||
        (!$_->{discNo} && $_->{trackNo} >= 100)
    } @trackArray;
}

sub fixMultiDiscSetTrackNumbers {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    foreach my $trackHash (@trackArray) {
        my $discNo  = $trackHash->{discNo};
        my $trackNo = $trackHash->{trackNo};
        if (!$discNo && $trackNo >= 100) {
            $trackHash->{discNo}  = floor($trackNo / 100);
            $trackHash->{trackNo} = $trackNo % 100;
        }
    }
}

sub tracksAreFromMultipleDiscs {
    my ($self, @trackArray) = @_;
    if (scalar @trackArray == 1 && ref $trackArray[0] eq 'ARRAY') {
        @trackArray = @{$trackArray[0]};
    }

    my @discNo = map { $_->{discNo} || 1 } @trackArray;
    my @uniqDiscNo = uniq sort { $a <=> $b } @discNo;
    return scalar @uniqDiscNo > 1;
}

1;
