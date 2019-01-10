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
has dry_run                   => (is => 'rw', default => 0);
has edited_tracks_by_filename => (is => 'rw', default => sub { return {}; });
has edited_tracks             => (is => 'rw', default => sub { return []; });
has force                     => (is => 'rw', default => 0);
has modified                  => (is => 'rw', default => 0);
has parse_filenames           => (is => 'rw', default => 0);
has tempname_mtime            => (is => 'rw');
has tempname                  => (is => 'rw');
has tracks_by_filename        => (is => 'rw', default => sub { return {}; });
has tracks                    => (is => 'rw', default => sub { return []; });
has verbose                   => (is => 'rw', default => 0);

sub run {
    my ($self, @filenames) = @_;
    $self->load_tags_from_files(@filenames);
    $self->fix_track_numbers($self->tracks);
    $self->create_tags_file_to_edit();
    $self->edit_tags_file();
    $self->load_tags_from_tags_file();
    $self->fix_track_numbers($self->edited_tracks);
    if ($self->modified || $self->dry_run || $self->force) {
        $self->save_tags();
    }
}

our $RX_INTEGER_OF_INTEGER;
our $RX_INTEGER;
BEGIN {
    $RX_INTEGER_OF_INTEGER = qr{(?: \s* (\d+) \s* (?:/|of) \s* (\d+) \s* )}xi;
    $RX_INTEGER            = qr{(?: \s* (\d+) \s*                        )}xi;
}

sub fix_track_numbers {
    my ($self, $track_array) = @_;
    foreach my $track_hash (@{$track_array}) {
        my $track = $track_hash->{track};
        if ($track =~ m{^ $RX_INTEGER_OF_INTEGER $}x) {
            $track_hash->{track_no} = $1 + 0;
            $track_hash->{track_of} = $2 + 0;
        } elsif ($track =~ m{^ $RX_INTEGER $}x) {
            $track_hash->{track_no} = $1 + 0;
            $track_hash->{track_of} = undef;
        }
    }
    my $sorted_track_numbers = join(",", sort { $a <=> $b } map { $_->{track_no} // 0 } @{$track_array});
    my $check_track_numbers  = join(",", 1 .. scalar(@{$track_array}));
    if ($sorted_track_numbers eq $check_track_numbers) {
        @{$track_array} = sort { $a->{track_no} <=> $b->{track_no} } @{$track_array};
        foreach my $track_hash (@{$track_array}) {
            $track_hash->{track_of} = scalar(@{$track_array});
            $track_hash->{old_track} = $track_hash->{track};
            $track_hash->{track} = sprintf("%d/%d", $track_hash->{track_no}, $track_hash->{track_of});
        }
        if (grep { $_->{track} ne $_->{old_track} } @{$track_array}) {
            $self->modified(1);
        }
    }

    # so arrays can be compared
    foreach my $track_hash (@{$track_array}) {
        # delete $track_hash->{track_no};
        # delete $track_hash->{track_of};
        # delete $track_hash->{old_track};
    }
}

sub fix_tpos {
    my ($self, $track_array) = @_;
    foreach my $track_hash (@{$track_array}) {
        if (defined $track_hash->{tpos}) {
            if ($track_hash->{tpos} =~ m{^ $RX_INTEGER_OF_INTEGER $}x) {
                my $new = sprintf("%d/%d", $1 + 0, $2 + 0);
                if ($new ne $track_hash->{tpos}) {
                    $track_hash->{tpos} = $new;
                    $self->modified(1);
                }
            } elsif ($track_hash->{tpos} =~ m{^ $RX_INTEGER $}x) {
                my $new = $1 + 0;
                if ($new ne $track_hash->{tpos}) {
                    $track_hash->{tpos} = $new;
                    $self->modified(1);
                }
            }
        }
    }
}

sub load_tags_from_files {
    my ($self, @filenames) = @_;
    $self->tracks([]);
    $self->tracks_by_filename({});
    foreach my $filename (@filenames) {
        next unless $filename =~ m{\.mp3$}i;

        my $mp3 = MP3::Tag->new($filename);
        if (!defined $mp3) {
            warn("edit-mp3-tags: could not read tags for $filename\n");
            next;
        }

        $mp3->config("prohibit_v24" => 0);
        $mp3->config("write_v24" => 1);

        my ($title, $track, $artist, $album, $comment, $year, $genre) = $mp3->autoinfo();
        my $album_artist = $mp3->select_id3v2_frame_by_descr("TPE2"); # "Band/orchestra/accompaniment"
        my $tcmp         = $mp3->select_id3v2_frame_by_descr("TCMP"); # iTunes Compilation Flag
        my $tpos         = $mp3->select_id3v2_frame_by_descr("TPOS"); # part of set (e.g., disc 1/2)
        my $composer     = $mp3->composer();
        my $performer    = $mp3->performer();

        my $track_hash = {
            track        => $track,
            artist       => $artist,
            title        => $title,
            album        => $album,
            year         => $year,
            tpos         => $tpos,

            genre        => $genre,
            album_artist => $album_artist,
            tcmp         => $tcmp,
            filename     => $filename,
            comment      => $comment,
            composer     => $composer,
            performer    => $performer,
        };

        my @keys = keys %$track_hash;
        foreach my $key (@keys) {
            if (is_blank($track_hash->{$key})) {
                delete $track_hash->{$key};
            }
        }

        if ($self->parse_filenames) {
            if ($filename =~ m{^
                               (?:(\d+)(?:\s*-+\s*|\s*\.\s*|\s+))?
                               (.*?)
                               (?:\s*-+\s*)
                               (.*?)
                               (?:\.mp3)?
                               $}xi) {
                my ($new_track, $new_artist, $new_title) = ($1, $2, $3);
                if (!is_blank($new_track)) {
                    $track_hash->{track} = $new_track;
                    $track_hash->{modified} = 1;
                    $self->modified(1);
                }
                if (!is_blank($new_artist)) {
                    $track_hash->{artist} = $new_artist;
                    $track_hash->{modified} = 1;
                    $self->modified(1);
                }
                if (!is_blank($new_title)) {
                    $track_hash->{title} = $new_title;
                    $track_hash->{modified} = 1;
                    $self->modified(1);
                }
            }
        }

        push(@{$self->tracks}, $track_hash);
        $self->tracks_by_filename->{$filename} = $track_hash;
    }
}

sub create_tags_file_to_edit {
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
        my $show_tpos = grep { !is_blank($_->{tpos}) } @{$self->tracks};
        my %column_widths = ();
        foreach my $column (qw(artist title album year album_artist)) {
            my @lengths = map { length($_) } grep { defined $_ } map { $_->{$column} } @{$self->tracks};
            if (scalar @lengths) {
                $column_widths{$column} = max @lengths;
            } else {
                $column_widths{$column} = 0;
            }
        }
        my $extra_space = 2;

        foreach my $track (@{$self->tracks}) {
            printf $fh ("%7s: ",              $track->{tpos} // "") if $show_tpos;
            printf $fh ("%7s. ",              $track->{track} // "");
            printf $fh ("artist=%-*s",        $extra_space + $column_widths{artist},       $track->{artist}       // "");
            printf $fh ("|title=%-*s",        $extra_space + $column_widths{title},        $track->{title}        // "");
            printf $fh ("|album=%-*s",        $extra_space + $column_widths{album},        $track->{album}        // "");
            printf $fh ("|year=%-*s",         $extra_space + $column_widths{year},         $track->{year}         // "");
            printf $fh ("|album-artist=%-*s", $extra_space + $column_widths{album_artist}, $track->{album_artist} // "");
            printf $fh ("|filename=%s",       $track->{filename} // "");
            print  $fh "\n";
        }
        $self->tempname_mtime((stat($tempname))[9]);
    } else {
        warn("No tracks.  Exiting.\n");
        exit(0);
    }
}

sub edit_tags_file {
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
        $self->editor_failed();
    } else {
        if ($mtime != $self->tempname_mtime) {
            $self->modified(1);
        }
    }
    if (!$self->modified) {
        if (!$self->force && !$self->dry_run) {
            $self->not_modified();
        }
    }
}

sub editor_failed {
    my ($self) = @_;
    warn("Editor failed.  Exiting.\n");
    unlink($self->tempname);
    exit(1);
}

sub not_modified {
    my ($self) = @_;
    warn("Not modified.  Exiting.\n");
    unlink($self->tempname);
    exit(0);
}

sub load_tags_from_tags_file {
    my ($self) = @_;
    my $tempname = $self->tempname;
    my $fh;
    open($fh, "<", $tempname) or die("Cannot read $tempname: $!\n");
    $self->album({});
    my $last_line_album = 0;
    my $last_line_track = 0;
    $self->edited_tracks([]);
    $self->edited_tracks_by_filename({});
    local $. = 0;
    while (<$fh>) {
        next if m{^\s*\#};      # ignore comments;
        s{\R\z}{};              # safer chomp
        next unless m{\S};      # skip blank lines

        if (!m{\|}) {
            if (!$last_line_album) {
                $self->album({});
            }
            s{^\s+}{};
            s{\s+$}{};
            if (m{\s*=\s*}) {
                my ($key, $value) = ($`, $');
                $key =~ s{-+}{_}g;
                if (is_blank($value)) {
                    delete $self->album->{$key};
                } else {
                    $self->album->{$key} = $value;
                }
            } else {
                s{-+}{_}g;
                $self->album->{$_} = 1;
            }
            $last_line_album = 1;
            $last_line_track = 0;
            next;
        }
        my $track_hash = {};

        if (s{^ ($RX_INTEGER_OF_INTEGER|$RX_INTEGER) \: \s* }{}x) {
            $track_hash->{tpos} = $1;
        }
        if (s{^ ($RX_INTEGER_OF_INTEGER|$RX_INTEGER) \. \s* }{}x) {
            $track_hash->{track} = $1;
        }

        my @kv = split(/\|/, $_);
        foreach (@kv) {
            s{^\s+}{};
            s{\s+$}{};
            if (m{\s*=\s*}) {
                my ($key, $value) = ($`, $');
                if (is_blank($value)) {
                    delete $track_hash->{$key};
                } else {
                    $track_hash->{$key} = $value;
                }
            } else {
                $track_hash->{$_} = 1;
            }
        }
        push(@{$self->edited_tracks}, $track_hash);
        $self->edited_tracks_by_filename->{$track_hash->{filename}} = $track_hash;
        if ($self->verbose >= 3) {
            warn Dumper($track_hash);
        }

        $last_line_album = 0;
        $last_line_track = 1;
    }
}

sub save_tags {
    my ($self) = @_;

    foreach my $track_hash (@{$self->edited_tracks}) {
        my $filename = $track_hash->{filename};
        if (is_blank($filename)) {
            warn("No filename on $filename line $.\n");
            next;
        }

        my $track    = $track_hash->{track};
        my $artist   = $self->album->{artist} // $track_hash->{artist};
        my $title    = $track_hash->{title};
        my $album    = $self->album->{album}  // $track_hash->{album};
        my $year     = $self->album->{year}   // $track_hash->{year};
        my $tpos     = $track_hash->{tpos};

        my $album_artist;
        if ($self->album->{various_artists}) {
            $album_artist = $artist;
            $artist = "Various Artists";
        }

        my $mp3 = MP3::Tag->new($filename);
        if (!defined $mp3) {
            warn("edit-mp3-tags: could not read tags for $filename\n");
            next;
        }

        $mp3->config("prohibit_v24" => 0);
        $mp3->config("write_v24" => 1);

        if ($self->verbose >= 2 || ($self->dry_run && $self->verbose)) {
            printf("%s\n", $filename);
            printf("  TRACK        = %s\n", $track        // "");
            printf("  ARTIST       = %s\n", $artist       // "");
            printf("  TITLE        = %s\n", $title        // "");
            printf("  ALBUM        = %s\n", $album        // "");
            printf("  YEAR         = %s\n", $year         // "");
            printf("  TPOS (DISC)  = %s\n", $tpos         // "");
            printf("  ALBUM_ARTIST = %s\n", $album_artist // "");
        }
        if (!$self->dry_run) {
            $mp3->title_set($title // "", 1);
            $mp3->artist_set($artist // "", 1);
            $mp3->year_set($year // "", 1);
            $mp3->album_set($album // "", 1);
            $mp3->track_set($track // "", 1);
            $mp3->select_id3v2_frame_by_descr("TPOS", $tpos // "");
            if ($self->album->{various_artists}) {
                $mp3->select_id3v2_frame_by_descr("TPE2", $album_artist);
                $mp3->select_id3v2_frame_by_descr("TCMP", "1");
            } else {
                $mp3->select_id3v2_frame_by_descr("TPE2", ''); # not undef
                $mp3->select_id3v2_frame_by_descr("TCMP", undef);
            }
            if ($self->verbose) {
                warn("Updating tags on $filename\n");
            }
            $mp3->update_tags(undef, 1);
        }
        if ($self->verbose && !$self->dry_run) {
            print("Done.\n");
        }
    }
}

sub is_blank {
    my ($string) = @_;
    return 1 if !defined $string;
    return 1 if $string !~ m{\S};
    return 0;
}

1;
