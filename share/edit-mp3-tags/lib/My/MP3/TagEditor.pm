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
use List::Util qw(max);

use Moo;

has album                     => (is => 'rw');
has dryRun                   => (is => 'rw', default => 0);
has editedTracksByFilename => (is => 'rw', default => sub { return {}; });
has editedTracks             => (is => 'rw', default => sub { return []; });
has force                     => (is => 'rw', default => 0);
has modified                  => (is => 'rw', default => 0);
has parseFilenames           => (is => 'rw', default => 0);
has tempnameMtime            => (is => 'rw');
has tempname                  => (is => 'rw');
has tracksByFilename        => (is => 'rw', default => sub { return {}; });
has tracks                    => (is => 'rw', default => sub { return []; });
has verbose                   => (is => 'rw', default => 0);

sub run {
    my ($self, @filenames) = @_;
    $self->loadTagsFromFiles(@filenames);
    $self->fixTrackNumbers($self->tracks);
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

sub fixTrackNumbers {
    my ($self, $trackArray) = @_;
    foreach my $trackHash (@{$trackArray}) {
        my $track = $trackHash->{track};
        if ($track =~ m{^ $RX_INTEGER_OF_INTEGER $}x) {
            $trackHash->{trackNo} = $1 + 0;
            $trackHash->{trackOf} = $2 + 0;
        } elsif ($track =~ m{^ $RX_INTEGER $}x) {
            $trackHash->{trackNo} = $1 + 0;
            $trackHash->{trackOf} = undef;
        }
    }
    my $sortedTrackNumbers = join(",", sort { $a <=> $b } map { $_->{trackNo} // 0 } @{$trackArray});
    my $checkTrackNumbers  = join(",", 1 .. scalar(@{$trackArray}));
    if ($sortedTrackNumbers eq $checkTrackNumbers) {
        @{$trackArray} = sort { $a->{trackNo} <=> $b->{trackNo} } @{$trackArray};
        foreach my $trackHash (@{$trackArray}) {
            $trackHash->{trackOf} = scalar(@{$trackArray});
            $trackHash->{oldTrack} = $trackHash->{track};
            $trackHash->{track} = sprintf("%d/%d", $trackHash->{trackNo}, $trackHash->{trackOf});
        }
        if (grep { $_->{track} ne $_->{oldTrack} } @{$trackArray}) {
            $self->modified(1);
        }
    }

    # so arrays can be compared
    foreach my $trackHash (@{$trackArray}) {
        # delete $trackHash->{trackNo};
        # delete $trackHash->{trackOf};
        # delete $trackHash->{oldTrack};
    }
}

sub fixTpos {
    my ($self, $trackArray) = @_;
    foreach my $trackHash (@{$trackArray}) {
        if (defined $trackHash->{tpos}) {
            if ($trackHash->{tpos} =~ m{^ $RX_INTEGER_OF_INTEGER $}x) {
                my $new = sprintf("%d/%d", $1 + 0, $2 + 0);
                if ($new ne $trackHash->{tpos}) {
                    $trackHash->{tpos} = $new;
                    $self->modified(1);
                }
            } elsif ($trackHash->{tpos} =~ m{^ $RX_INTEGER $}x) {
                my $new = $1 + 0;
                if ($new ne $trackHash->{tpos}) {
                    $trackHash->{tpos} = $new;
                    $self->modified(1);
                }
            }
        }
    }
}

sub loadTagsFromFiles {
    my ($self, @filenames) = @_;
    $self->tracks([]);
    $self->tracksByFilename({});
    foreach my $filename (@filenames) {
        next unless $filename =~ m{\.mp3$}i;

        my $mp3 = MP3::Tag->new($filename);
        if (!defined $mp3) {
            warn("edit-mp3-tags: could not read tags for $filename\n");
            next;
        }

        $mp3->config("prohibitV24" => 0);
        $mp3->config("writeV24" => 1);

        my ($title, $track, $artist, $album, $comment, $year, $genre) = $mp3->autoinfo();
        my $albumArtist = $mp3->selectId3v2FrameByDescr("TPE2"); # "Band/orchestra/accompaniment"
        my $tcmp         = $mp3->selectId3v2FrameByDescr("TCMP"); # iTunes Compilation Flag
        my $tpos         = $mp3->selectId3v2FrameByDescr("TPOS"); # part of set (e.g., disc 1/2)
        my $composer     = $mp3->composer();
        my $performer    = $mp3->performer();

        my $trackHash = {
            track        => $track,
            artist       => $artist,
            title        => $title,
            album        => $album,
            year         => $year,
            tpos         => $tpos,

            genre        => $genre,
            albumArtist => $albumArtist,
            tcmp         => $tcmp,
            filename     => $filename,
            comment      => $comment,
            composer     => $composer,
            performer    => $performer,
        };

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

sub createTagsFileToEdit {
    my ($self, @filenames) = @_;
    if (scalar @{$self->tracks}) {
        my ($fh, $tempname) = tempfile();
        $self->tempname($tempname);
        print $fh <<"EOF";
# Lines starting with '#' are ignored.

# Un-comment the following line for various-artists compilations.
#various-artists

# Un-comment and edit any of the following line(s) for albums.
#artist=<artist>
#album=<album>
#year=<year>

# For multi-disc sets, prefix each line with:       1/2:   (optional)
# Then if you need to fix track numbers manually:   1/10.

# Make changes, save, and exit your editor to effect your changes.
# Blank out this file to cancel all changes.

EOF
        my $showTpos = grep { !isBlank($_->{tpos}) } @{$self->tracks};
        my %columnWidths = ();
        foreach my $column (qw(artist title album year albumArtist)) {
            my @lengths = map { length($_) } grep { defined $_ } map { $_->{$column} } @{$self->tracks};
            if (scalar @lengths) {
                $columnWidths{$column} = max @lengths;
            } else {
                $columnWidths{$column} = 0;
            }
        }
        my $extraSpace = 2;

        foreach my $track (@{$self->tracks}) {
            printf $fh ("%7s: ",              $track->{tpos} // "") if $showTpos;
            printf $fh ("%7s. ",              $track->{track} // "");
            printf $fh ("artist=%-*s",        $extraSpace + $columnWidths{artist},       $track->{artist}       // "");
            printf $fh ("|title=%-*s",        $extraSpace + $columnWidths{title},        $track->{title}        // "");
            printf $fh ("|album=%-*s",        $extraSpace + $columnWidths{album},        $track->{album}        // "");
            printf $fh ("|year=%-*s",         $extraSpace + $columnWidths{year},         $track->{year}         // "");
            printf $fh ("|album-artist=%-*s", $extraSpace + $columnWidths{albumArtist}, $track->{albumArtist} // "");
            printf $fh ("|filename=%s",       $track->{filename} // "");
            print  $fh "\n";
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
    $self->album({});
    my $lastLineAlbum = 0;
    my $lastLineTrack = 0;
    $self->editedTracks([]);
    $self->editedTracksByFilename({});
    local $. = 0;
    while (<$fh>) {
        next if m{^\s*\#};      # ignore comments;
        s{\R\z}{};              # safer chomp
        next unless m{\S};      # skip blank lines

        if (!m{\|}) {
            if (!$lastLineAlbum) {
                $self->album({});
            }
            s{^\s+}{};
            s{\s+$}{};
            if (m{\s*=\s*}) {
                my ($key, $value) = ($`, $');
                $key =~ s{-+}{_}g;
                if (isBlank($value)) {
                    delete $self->album->{$key};
                } else {
                    $self->album->{$key} = $value;
                }
            } else {
                s{-+}{_}g;
                $self->album->{$_} = 1;
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
        push(@{$self->editedTracks}, $trackHash);
        $self->editedTracksByFilename->{$trackHash->{filename}} = $trackHash;
        if ($self->verbose >= 3) {
            warn Dumper($trackHash);
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

        my $track    = $trackHash->{track};
        my $artist   = $self->album->{artist} // $trackHash->{artist};
        my $title    = $trackHash->{title};
        my $album    = $self->album->{album}  // $trackHash->{album};
        my $year     = $self->album->{year}   // $trackHash->{year};
        my $tpos     = $trackHash->{tpos};

        my $albumArtist;
        if ($self->album->{variousArtists}) {
            $albumArtist = $artist;
            $artist = "Various Artists";
        }

        my $mp3 = MP3::Tag->new($filename);
        if (!defined $mp3) {
            warn("edit-mp3-tags: could not read tags for $filename\n");
            next;
        }

        $mp3->config("prohibitV24" => 0);
        $mp3->config("writeV24" => 1);

        if ($self->verbose >= 2 || ($self->dryRun && $self->verbose)) {
            printf("%s\n", $filename);
            printf("  TRACK        = %s\n", $track        // "");
            printf("  ARTIST       = %s\n", $artist       // "");
            printf("  TITLE        = %s\n", $title        // "");
            printf("  ALBUM        = %s\n", $album        // "");
            printf("  YEAR         = %s\n", $year         // "");
            printf("  TPOS (DISC)  = %s\n", $tpos         // "");
            printf("  ALBUM_ARTIST = %s\n", $albumArtist // "");
        }
        if (!$self->dryRun) {
            $mp3->titleSet($title // "", 1);
            $mp3->artistSet($artist // "", 1);
            $mp3->yearSet($year // "", 1);
            $mp3->albumSet($album // "", 1);
            $mp3->trackSet($track // "", 1);
            $mp3->selectId3v2FrameByDescr("TPOS", $tpos // "");
            if ($self->album->{variousArtists}) {
                $mp3->selectId3v2FrameByDescr("TPE2", $albumArtist);
                $mp3->selectId3v2FrameByDescr("TCMP", "1");
            } else {
                $mp3->selectId3v2FrameByDescr("TPE2", ''); # not undef
                $mp3->selectId3v2FrameByDescr("TCMP", undef);
            }
            if ($self->verbose) {
                warn("Updating tags on $filename\n");
            }
            $mp3->updateTags(undef, 1);
        }
        if ($self->verbose && !$self->dryRun) {
            print("Done.\n");
        }
    }
}

sub isBlank {
    my ($string) = @_;
    return 1 if !defined $string;
    return 1 if $string !~ m{\S};
    return 0;
}

1;
