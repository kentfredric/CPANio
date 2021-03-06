package CPANio::Game::Regular;

use 5.010;
use strict;
use warnings;
use Carp;
use BackPAN::Index;

use CPANio;
use CPANio::Game;
our @ISA = qw( CPANio::Game );

use CPANio::Bins;

# CONSTANTS
my %LIKE = (
    month => 'M%',
    week  => 'W%',
    day   => 'D%',
);

sub resultclass_name {
    my ($class) = @_;
    die "resultclass_name not defined for $class";
}

# PRIVATE FUNCTIONS

sub _authors_chains {
    my ( $resultclass_name, @periods ) = @_;
    my $schema  = $CPANio::schema;
    my $bins_rs = $schema->resultset($resultclass_name);

    my %chains;
    for my $period (@periods) {

        # pick the bins for the current period
        my $bins = CPANio::Bins->bins_since()->{$period};

        # get the list of bins for all the authors
        my %bins;
        push @{ $bins{ $_->author } }, $_->bin
            for $bins_rs->search(
            { author => { '!=' => '' }, bin => { like => $LIKE{$period} } },
            { order_by => { -desc => 'bin' } }
            );

        # process each author's bins
        for my $author ( keys %bins ) {
            my $Bins = delete $bins{$author};
            my @chains;
            my $i = 0;

            # split the bins into chains
            while (@$Bins) {
                $i++ while $Bins->[0] ne $bins->[$i];
                my $j = 0;
                while ( $Bins->[$j] eq $bins->[$i] ) {
                    $i++;
                    $j++;
                    last if $j >= @$Bins;
                }
                my $chain = [ splice @$Bins, 0, $j ];
                push @chains, $chain if @$chain >= 2;
            }
            $bins{$author} = \@chains if @chains;
        }
        $chains{$period} = \%bins;
    }

    return \%chains;
}

sub _commit_entries {
    my ( $period, $game, $contest, $entries ) = @_;

    # compute rank
    my $Rank = my $rank = my $prev = 0;
    my %seen;
    for my $entry (@$entries) {
        $Rank++ unless $seen{ $entry->{author} }++    # rank each author once
                || ( $entry->{fallen} && $contest eq 'current' );
        $rank          = $Rank if $entry->{count} != $prev;
        $prev          = $entry->{count};
        $entry->{rank} = $rank;
    }

    # update database
    my $rs = $CPANio::schema->resultset("OnceA\u$period");
    $rs->search( { game => $game, contest => $contest } )->delete();
    $rs->populate($entries);
}

sub _compute_boards_current {
    my ( $chains, $game, $period ) = @_;

    # pick the bins for the current period
    my $bins = CPANio::Bins->bins_since()->{$period};

    # only keep the active chains
    my @entries;
    for my $author ( keys %{ $chains->{$period} } ) {
        my $chain = $chains->{$period}{$author}[0];    # current chain only
        if (   $chain->[0] eq $bins->[0]
            || $chain->[0] eq $bins->[1]
            || $chain->[0] eq $bins->[2] )
        {
            push @entries, {
                game    => $game,
                contest => 'current',
                author  => $author,
                count   => scalar @$chain,
                safe    => 0 + ( $chain->[0] eq $bins->[0] ),
                active  => 0,
                fallen  => 0 + ( $chain->[0] eq $bins->[2] ),
                };
        }
    }

    # sort chains
    @entries = sort { $b->{count} <=> $a->{count} || $a->{fallen} <=> $b->{fallen} }
        grep $_->{count} >= 2,
        @entries;

    _commit_entries( $period, $game, 'current', \@entries );
}

sub _compute_boards_alltime {
    my ( $chains, $game, $period ) = @_;

    # pick the bins for the current period
    my $bins = CPANio::Bins->bins_since()->{$period};

    my @entries = map {
        my $author = $_;
        my @chains = @{ $chains->{$period}{$author} };
        my $chain  = shift @chains;                  # possibly active
        {   game    => $game,
            contest => 'all-time',
            author  => $author,
            count   => scalar @$chain,
            safe    => 0 + ( $chain->[0] eq $bins->[0] ),
            active  => 0 + ( $chain->[0] eq $bins->[1] ),
            fallen  => 0 + ( $chain->[0] eq $bins->[2] ),
        },
            map +{
            game    => $game,
            contest => 'all-time',
            author  => $author,
            count   => scalar @$_,
            safe    => 0,
            active  => 0,
            fallen  => 0,
            }, @chains;
    } keys %{ $chains->{$period} };

    # sort chains, and keep only one per author
    my %seen;
    @entries = grep $seen{ $_->{author} }++ ? $_->{safe} || $_->{active} || $_->{fallen} : 1,
        sort { $b->{count} <=> $a->{count} }
        grep $_->{count} >= 2,
        @entries;

    _commit_entries( $period, $game, 'all-time', \@entries );
}

sub _compute_boards_yearly {
    my ( $chains, $game, $period ) = @_;
    my @years = ( 1995 .. 1900 + (gmtime)[5] );

    # pick the bins for the current period
    my $bins = CPANio::Bins->bins_since()->{$period};

    for my $year (@years) {
        my @entries = map {
            my $author = $_;   # keep the sub-chains that occured during $year
            my @chains = grep @$_, map [ grep /^\w$year\b/, @$_ ],
                @{ $chains->{$period}{$author} };
            @chains
                ? do {
                my $active = $bins->[0] =~ /^\w$year\b/;
                my $chain = shift @chains;    # possibly active
                {   game    => $game,
                    contest => $year,
                    author  => $author,
                    count   => scalar @$chain,
                    safe    => 0 + ( $active && $chain->[0] eq $bins->[0] ),
                    active  => 0 + ( $active && $chain->[0] eq $bins->[1] ),
                    fallen  => 0 + ( $active && $chain->[0] eq $bins->[2] ),
                },
                    map +{
                    game    => $game,
                    contest => $year,
                    author  => $author,
                    count   => scalar @$_,
                    safe    => 0,
                    active  => 0,
                    fallen  => 0,
                    },
                    @chains;
                }
                : ();
        } keys %{ $chains->{$period} };

        # sort chains, and keep only one per author
        my %seen;
        @entries = grep $seen{ $_->{author} }++ ? $_->{safe} || $_->{active} || $_->{fallen} : 1,
            sort { $b->{count} <=> $a->{count} }
            grep $_->{count} >= 2,
            @entries;

        _commit_entries( $period, $game, $year, \@entries );
    }
}

# VIRTUAL METHODS

sub compute_author_bins {
    my ($class) = @_;
    die "compute_author_bins not defined for $class";
}

sub periods {
    my ($class) = @_;
    die "periods not defined for $class";
}

# CLASS METHODS

sub author_periods { shift->periods; }

sub bins_rs {
    my ( $class, $period, $prefix ) = @_;
    my $bins_rs = $CPANio::schema->resultset( $class->resultclass_name );

    if ($period) {
        croak "Unknonw period $period" if !exists $LIKE{$period};
        my $like = $LIKE{$period};
        $like =~ s/%/$prefix%/ if $prefix;
        return $bins_rs->search(
            { bin      => { like  => $like } },
            { order_by => { -desc => 'bin' } }
        );
    }

    return $bins_rs;
}

sub backpan {
    state $backpan = BackPAN::Index->new(
        cache_ttl => 3600,    # 1 hour
        backpan_index_url =>
            "http://backpan.cpantesters.org/backpan-full-index.txt.gz",
    );
    return $backpan;
}

sub get_releases {
    my ( $class, $since ) = @_;
    $since ||= $CPANio::Bins::FIRST_RELEASE_TIME - 1;

    return $class->backpan->releases->search(
        { date     => { '>', $since } },
        { order_by => 'date', prefetch => 'dist' }
    );
}

sub update_author_bins {
    my ($class) = @_;
    my ( $bins, $latest_release ) = $class->compute_author_bins();

    my $bins_rs = $CPANio::schema->resultset( $class->resultclass_name );
    $CPANio::schema->txn_do(
        sub {
            if ( $bins_rs->count ) {    # update
                for my $bin ( keys %$bins ) {
                    for my $author ( keys %{ $bins->{$bin} } ) {
                        my $row = $bins_rs->find_or_create(
                            { author => $author, bin => $bin } );
                        $row->count(
                            ( $row->count || 0 ) + $bins->{$bin}{$author} );
                        $row->update;
                    }
                }
            }
            else {                      # create
                $bins_rs->populate(
                    [   map {
                            my $bin = $_;
                            map +{
                                bin    => $bin,
                                author => $_,
                                count  => $bins->{$bin}{$_}
                                },
                                keys %{ $bins->{$bin} }
                            } keys %$bins
                    ]
                );
            }
            $class->update_done($latest_release);
        }
    );

    return $latest_release;
}

sub update_boards {
    my ( $class, @periods ) = @_;

    # pick up all the chains
    my $chains = _authors_chains( $class->resultclass_name, @periods );

    # compute all contests
    for my $period (@periods) {
        _compute_boards_current( $chains, $class->game_name, $period );
        _compute_boards_alltime( $chains, $class->game_name, $period );
        _compute_boards_yearly( $chains, $class->game_name, $period );
    }
}

sub update {
    my ($class)  = @_;
    my $previous = $class->latest_update;
    my $latest   = $class->update_author_bins();

    $class->update_boards( $class->author_periods )
        if $latest > $previous;
}

1;
