package App::Sqitch::Engine::oracle;

use 5.010;
use Mouse;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use List::Util qw(first);
use namespace::autoclean;

extends 'App::Sqitch::Engine';
sub dbh; # required by DBIEngine;
with 'App::Sqitch::Role::DBIEngine';

our $VERSION = '0.966';

BEGIN {
    # We tell the Oracle connector which encoding to use. The last part of the
    # environment variable NLS_LANG is relevant concerning data encoding.
    $ENV{NLS_LANG} = 'AMERICAN_AMERICA.AL32UTF8';

    # Disable SQLPATH so that no start scripts run.
    $ENV{SQLPATH} = '';
}

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.oracle.client' )
            || file(
                ($ENV{ORACLE_HOME} || ()),
                'sqlplus' . ( $^O eq 'MSWin32' ? '.exe' : '' )
            )->stringify;
    },
);

has username => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_username || $sqitch->config->get( key => 'core.oracle.username' );
    },
);

has password => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        shift->sqitch->config->get( key => 'core.oracle.password' );
    },
);

has db_name => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->sqitch;
        $sqitch->db_name || $sqitch->config->get( key => 'core.oracle.db_name' );
    },
);

has destination => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        $self->db_name
            || $ENV{TWO_TASK}
            || ( $^O eq 'MSWin32' ? $ENV{LOCAL} : undef )
            || $ENV{ORACLE_SID}
            || $self->username
            || $self->sqitch->sysuser
    },
);

has host => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_host || $sqitch->config->get( key => 'core.oracle.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_port || $sqitch->config->get( key => 'core.oracle.port' );
    },
);

has sqitch_schema => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.oracle.sqitch_schema' )
    },
);

has sqlplus => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        [ $self->client, qw(-S -L /nolog) ];
    },
);

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        # XXX require DBD::Oracle 1.23.
        try { require DBD::Oracle } catch {
            hurl oracle => __ 'DBD::Oracle module required to manage Oracle' if $@;
        };

        my $dsn = 'dbi:Oracle:';
        if ($self->host || $self->port) {
            $dsn .=  join ';' => map {
                "$_->[0]=$_->[1]"
            } grep { $_->[1] } (
                [ sid   => $self->db_name ],
                [ host  => $self->host    ],
                [ port  => $self->port    ],
            );
        } else {
            $dsn .= $self->db_name if $self->db_name;
        }

        DBI->connect($dsn, $self->username, $self->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            FetchHashKeyName  => 'NAME_lc',
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks         => {
                connected => sub {
                    my $dbh = shift;
                    $dbh->do("ALTER SESSION SET $_='YYYY-MM-DD HH24:MI:SS TZR'") for qw(
                        nsl_date_format
                        nls_timestamp_format
                        nls_timestamp_tz_format
                    );
                    if (my $schema = $self->sqitch_schema) {
                        $dbh->do("ALTER SESSION SET CURRENT_SCHEMA = $schema");
                    }
                    return;
                },
            },
        });
    }
);

sub config_vars {
    return (
        client        => 'any',
        username      => 'any',
        password      => 'any',
        db_name       => 'any',
        host          => 'any',
        port          => 'int',
        sqitch_schema => 'any',
    );
}

sub _log_tags_param {
    [ map { $_->format_name } $_[1]->tags ];
}

sub _log_requires_param {
    [ map { $_->as_string } $_[1]->requires ];
}

sub _log_conflicts_param {
    [ map { $_->as_string } $_[1]->conflicts ];
}

sub _ts2char_format {
     q{to_char(%s AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

sub _ts_default { 'current_timestamp' }

sub _char2ts {
    my $dt = $_[1];
    join ' ', $dt->ymd('-'), $dt->hms(':'), $dt->time_zone->name;
}

sub _listagg_format {
    # http://stackoverflow.com/q/16313631/79202
    return q{COLLECT(%s)};
}

sub _regex_op { 'REGEXP_LIKE(%s, ?)' }

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    return try {
        $self->dbh->selectcol_arrayref(qq{
            SELECT * FROM (
                SELECT change_id
                  FROM changes
                 WHERE project = ?
                 ORDER BY committed_at $ord
            ) WHERE rownum >= ?
        }, undef, $project || $self->plan->project, ($offset // 0) + 1)->[0];
    } catch {
        return if $self->_no_table_error;
        die $_;
    };
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $dbh    = $self->dbh;
    # XXX Oy, placeholders do not work with COLLECT() in this query.
    my $qproj  = $dbh->quote($project // $self->plan->project);
    my $state  = $dbh->selectrow_hashref(qq{
        SELECT * FROM (
            SELECT c.change_id
                 , c.change
                 , c.project
                 , COALESCE(c.note, '')
                 , c.committer_name
                 , c.committer_email
                 , $cdtcol AS committed_at
                 , c.planner_name
                 , c.planner_email
                 , $pdtcol AS planned_at
                 , $tagcol AS tags
              FROM changes   c
              LEFT JOIN tags t ON c.change_id = t.change_id
             WHERE c.project = $qproj
             GROUP BY c.change_id
                 , c.change
                 , c.project
                 , c.note
                 , c.committer_name
                 , c.committer_email
                 , c.committed_at
                 , c.planner_name
                 , c.planner_email
                 , c.planned_at
             ORDER BY c.committed_at DESC
        ) WHERE rownum = 1
    }) or return undef;
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(
        'SELECT 1 FROM changes WHERE change_id = ?',
        undef, $change->id
    )->[0];
}

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT 1
          FROM all_tables
         WHERE owner = SYS_CONTEXT('USERENV', 'SESSION_SCHEMA')
           AND table_name = 'CHANGES'
    })->[0];
}

sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;

    $tags      ||= $self->_log_tags_param($change);
    $requires  ||= $self->_log_requires_param($change);
    $conflicts ||= $self->_log_conflicts_param($change);

    # Use the sqitch_array() constructor to insert arrays of values.
    my $tag_ph = 'sqitch_array('. join(', ', ('?') x @{ $tags      }) . ')';
    my $req_ph = 'sqitch_array('. join(', ', ('?') x @{ $requires  }) . ')';
    my $con_ph = 'sqitch_array('. join(', ', ('?') x @{ $conflicts }) . ')';
    my $ts     = $self->_ts_default;

    $dbh->do(qq{
        INSERT INTO events (
              event
            , change_id
            , change
            , project
            , note
            , tags
            , requires
            , conflicts
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
            , committed_at
        )
        VALUES (?, ?, ?, ?, ?, $tag_ph, $req_ph, $con_ph, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        @{ $tags      },
        @{ $requires  },
        @{ $conflicts },
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub initialize {
    my $self   = shift;
    my $schema = $self->sqitch_schema;
    hurl engine => __ 'Sqitch already initialized' if $self->initialized;

    # Load up our database.
    (my $file = file(__FILE__)->dir->file('oracle.sql')) =~ s/"/""/g;
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');

    $self->$meth(
        (
            $schema ? (
                "DEFINE sqitch_schema=$schema"
            ) : (
                # Select the current schema into &sqitch_schema.
                # http://www.orafaq.com/node/515
                'COLUMN sname for a30 new_value sqitch_schema',
                q{SELECT SYS_CONTEXT('USERENV', 'SESSION_SCHEMA') AS sname FROM DUAL;},
            )
        ),
        qq{\@"$file"}
    );

    $self->dbh->do("ALTER SESSION SET CURRENT_SCHEMA = $schema") if $schema;
    return $self;
}

# Override to lock the changes table. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE');
    return $self;
}

sub run_file {
    my $self = shift;
    (my $file = shift) =~ s/"/""/g;
    $self->_run(qq{\@"$file"});
}

sub run_verify {
    my $self = shift;
    (my $file = shift) =~ s/"/""/g;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth(qq{\@"$file"});
}

sub run_handle {
    my ($self, $fh) = @_;
    my $target = $self->_script;
    open my $tfh, '<:utf8_strict', \$target;
    $self->sqitch->spool( [$tfh, $fh], $self->sqlplus );
}

# Override to take advantage of the RETURNING expression, and to save tags as
# an array rather than a space-delimited string.
sub log_revert_change {
    my ($self, $change) = @_;
    my $dbh = $self->dbh;

    # Delete tags.
    my $del_tags = $dbh->selectcol_arrayref(
        'DELETE FROM tags WHERE change_id = ? RETURNING tag',
        undef, $change->id
    ) || [];

    # Retrieve dependencies.
    my ($req, $conf) = $dbh->selectrow_array(q{
        SELECT ARRAY(
            SELECT dependency
              FROM dependencies
             WHERE change_id = $1
               AND type = 'require'
        ), ARRAY(
            SELECT dependency
              FROM dependencies
             WHERE change_id = $1
               AND type = 'conflict'
        )
    }, undef, $change->id);

    # Delete the change record.
    $dbh->do(
        'DELETE FROM changes where change_id = ?',
        undef, $change->id,
    );

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $req, $conf );
}

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

sub _dt($) {
    require App::Sqitch::DateTime;
    my %params;
    @params{qw(time_zone year month day hour minute second)} = (
        'UTC',
        split /:/ => shift
    );
    return App::Sqitch::DateTime->new(%params);
}

sub _no_table_error  {
    return $DBI::err == 942; # ORA-00942: table or view does not exist
}

sub _in_expr {
    my ($self, $vals) = @_;
    return 'IN(SELECT * FROM TABLE(?))', $vals;
}

sub _script {
    my $self   = shift;
    my $target = $self->username // '';
    if (my $pass = $self->password) {
        $pass =~ s/"/""/g;
        $target .= qq{/"$pass"};
    }
    if (my $db = $self->db_name) {
        $target .= '@';
        $db =~ s/"/""/g;
        if ($self->host || $self->port) {
            $target .= '//' . ($self->host || '');
            if (my $port = $self->port) {
                $target .= ":$port";
            }
            $target .= qq{/"$db"};
        } else {
            $target .= qq{"$db"};
        }
    }
    my %vars = $self->variables;

    return join "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        (map {; (my $v = $vars{$_}) =~ s/"/""/g; qq{DEFINE $_="$v"} } sort keys %vars),
        "connect $target",
        @_
    );
}

sub _run {
    my $self = shift;
    my $script = $self->_script(@_);
    open my $fh, '<:utf8_strict', \$script;
    return $self->sqitch->spool( $fh, $self->sqlplus );
}

sub _capture {
    my $self = shift;
    my $target = $self->_script(@_);
    my @out;

    require IPC::Run3;
    IPC::Run3::run3( [$self->sqlplus], \$target, \@out );
    if (my $err = $?) {
        # Ugh, send everything to STDERR.
        $self->sqitch->vent(@out);
        hurl io => __x(
            '{command} unexpectedly returned exit value {exitval}',
            command => $self->client,
            exitval => ($err >> 8),
        );
    }

    return wantarray ? @out : \@out;
}

__PACKAGE__->meta->make_immutable;
no Mouse;

__END__

=head1 Name

App::Sqitch::Engine::oracle - Sqitch Oracle Engine

=head1 Synopsis

  my $oracle = App::Sqitch::Engine->load( engine => 'oracle' );

=head1 Description

App::Sqitch::Engine::oracle provides the Oracle storage engine for Sqitch. It
supports Oracle 8.4.0 and higher.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::oracle->config_vars;

Returns a hash of names and types to use for variables in the C<core.oracle>
section of the a Sqitch configuration file. The variables and their types are:

  client        => 'any'
  username      => 'any'
  password      => 'any'
  db_name       => 'any'
  host          => 'any'
  port          => 'int'
  sqitch_schema => 'any'

=head2 Instance Methods

=head3 C<initialized>

  $oracle->initialize unless $oracle->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $oracle->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2013 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
