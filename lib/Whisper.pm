# Original Copyright 2008 Orbitz WorldWide (python)
# Perl port 2013 Jean Stebens (perl)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package Whisper;

use strict;
use warnings;

our $VERSION;

use base 'Exporter';
our @EXPORT    = qw( wsp_info wsp_fetch );

# ABSTRACT: Handle Whisper fixed-size database files
 
# This module is an implementation of the Whisper database API
# Here is the basic layout of a whisper data file .wsp:
#
# File = Header,Data
#       Header = Metadata,ArchiveInfo+
#               Metadata = aggregationType,maxRetention,xFilesFactor,archiveCount
#               ArchiveInfo = Offset,SecondsPerPoint,Points
#       Data = Archive+
#               Archive = Point+
#                       Point = timestamp,value

my $metadata_Format = "N2f>N";
my $metadata_Size = length pack($metadata_Format, 0);

my $archiveInfo_Format = "N3";
my $archiveInfo_Size = length pack($archiveInfo_Format, 0);

my $point_Format = "Nd>";
my $point_Size = length pack($point_Format, 0);

my $long_Format = "N";
my $long_Size = length pack($long_Format, 0);

my $float_Format = "f";
my $float_Size = length pack($float_Format, 0);

my $value_Format = "d";
my $value_Size = length pack($value_Format, 0);

my $aggtype = {
	1 => 'average',
	2 => 'sum',
	3 => 'last',
	4 => 'max',
	5 => 'min'
};

sub __read_header {
	my $file = shift;

	read($file, my $rec, $metadata_Size) or die("unable to read");
	my ($aggregationType, $maxRetention, $xff, $archiveCount) = unpack($metadata_Format, $rec);
	
	my $archives = [];
	foreach(0..$archiveCount-1) {
        push(@$archives, __read_archiveinfo($file));
	}

	return {
		aggregationType => $aggregationType,
		maxRetention => $maxRetention,
		xFilesFactor => $xff,
		archiveCount => $archiveCount,
		archives => $archives,
		fileSize => (stat($file))[7],
	};
}

sub __read_archiveinfo {
	my $file = shift;

	read($file, my $rec, $archiveInfo_Size) or die("unable to read");
	my ($offset, $secondsPerPoint, $points) = unpack($archiveInfo_Format, $rec);

	return {
		offset => $offset,
		secondsPerPoint => $secondsPerPoint,
		points => $points,
		retention => $secondsPerPoint * $points,
		size => $points * $point_Size,
	};
}

sub wsp_info {
	my $dbfile = shift;

	die("You need to specify a wsp file\n") unless $dbfile;

	open(my $file, "<", $dbfile) or die("Unable to read whisper file: $dbfile\n");
	binmode($file); 

	my $header = __read_header($file);
	$header->{fileSize} = (stat($file))[7];

	close($file);
	return $header;
}

sub wsp_fetch {
	my ($dbfile, $from, $until) = @_;

	die("You need to specify a wsp file\n") unless $dbfile;
	
	open(my $file, "<", $dbfile) or die("Unable to read whisper file: $dbfile\n");
	binmode($file); 

	my $header = __read_header($file);

	my $now = time;
	my $oldest = $now - $header->{maxRetention};

	# defaults
	$until ||= $now;
	$from ||= 0;

	die("Invalid time interval") unless $from < $until;

	# from borders
	$from = $oldest if $from < $oldest;

	# until borders
	$until = $now if $until > $now;

	my $diff = $now - $from;

	my $archive;
	# Get first archive which spans our wanted timeslot
	foreach my $a (@{ $header->{archives} }) {
		if( $a->{retention} >= $diff ) {
			$archive = $a;
			last;
		}
	}
	die("No archive satisfies our needs") unless $archive;

	my $from_interval = ($from - ( $from % $archive->{secondsPerPoint})) + $archive->{secondsPerPoint};
	my $until_interval = ($until - ( $until % $archive->{secondsPerPoint})) + $archive->{secondsPerPoint};

	my $offset = $archive->{offset};

	seek($file, $offset, 0);
	read($file, my $packed_point, $point_Size) or die("unable to read");
	my ($base_interval, $base_value) = unpack($point_Format, $packed_point);

	if( $base_interval == 0 ) {
		my $step = $archive->{secondsPerPoint};
		my $points = ($until_interval - $from_interval) / $step;
		my @timeinfo = ($from_interval, $until_interval, $step);
		my @values = (undef) x $points;
		return { 
			from => $from_interval, 
			until => $until_interval,
			step => $step,
			values => \@values,
			cnt => scalar @values,
		}
	}

	# Determine fromOffset
	my $from_time_distance = $from_interval - $base_interval;
	my $from_point_distance = $from_time_distance / $archive->{secondsPerPoint};
	my $from_byte_distance = $from_point_distance * $point_Size;
	my $from_offset = $archive->{offset} + ( $from_byte_distance % $archive->{size});

	# Determine untilOffset
	my $until_time_distance = $until_interval - $base_interval;
	my $until_point_distance = $until_time_distance / $archive->{secondsPerPoint};
	my $until_byte_distance = $until_point_distance * $point_Size;
	my $until_offset = $archive->{offset} + ( $until_byte_distance % $archive->{size});

	# Read all the points in the interval
	seek($file, $from_offset, 0);
	my $series;
	if( $from_offset < $until_offset ) {
		read($file, $series, ($until_offset - $from_offset));
	} else {
		#We do wrap around the archive, so we need two reads
		my $archive_end = $archive->{offset} + $archive->{size};
		read($file, my $first, $archive_end - $from_offset);
		seek($file, $archive->{offset}, 0 );
		read($file, my $second, $until_offset - $archive->{offset});
		$series = $first . $second;
	
	}

	# Unpack the series
	my $points = length($series) / $point_Size;
	my $series_format = $point_Format x $points;
	my @series_unpacked = unpack($series_format, $series);

	my $values = [ (undef) x $points ];
	my $current_interval = $from_interval;
	my $step = $archive->{secondsPerPoint};

	my $index = 0;
	while( @series_unpacked ) {
		my ($point_time, $point_value ) = splice(@series_unpacked, 0, 2);
		if( $point_time == $current_interval ) {
			$values->[$index] = sprintf("%f", $point_value);
		}
		$current_interval += $step;
		$index++;
	}

	close($file);

	return {
		from => $from_interval,
		until => $until_interval,
		step => $step,
		values => $values,
		cnt => scalar @$values,
	}
} 
     
1;

__END__

=head1 NAME

Whisper - Handle Whisper fixed-size database files

=head1 SYNOPSIS

	use Whisper;

	# Read archive information
	my $info = wsp_info("/path/to/my/database.wsp"); 

	# Fetch archive data
	my $data = wsp_fetch("/path/to/my/database.wsp", $from, $until);


=head1 DESCRIPTION

This is a simple Whisper (fixed-size database) reader.

Whisper archive/databse files (.wsp) are similiar to RRD archive files. 
For more details about Whisper see L<http://graphite.wikidot.com/whisper>

The following operations are supported:

	wsp_info	Read basic archive information
	wsp_fetch	Fetch data points from archive

These operations are planned:

	wsp_create	Create wsp database
	wsp_update	Add a data point to a wsp database
	wsp_update_bulk	Add multiple data points to a wsp database
	wsp_merge	Merge two wsp database files

Feel free to help implement the above operations.
 
=head1 EXPORTS
 
By default, C<use Whisper> exports all the functions listed below.  

=head1 FUNCTIONS

=head2 wsp_info ($file)

=head3 Parameters

	path    Simple string file path

=head3 Returns

Returns a hash reference with Header/Metadata information:

	{
		'aggregationType' => 1,
		'fileSize' => 32872,
		'archiveCount' => 2,
		'xFilesFactor' => '0.5',
		'maxRetention' => 2592000

		'archives' => [
			{
				'secondsPerPoint' => 300,
				'points' => 2016,
				'retention' => 604800,
				'size' => 24192,
				'offset' => 40
			},
			{
				'secondsPerPoint' => 3600,
				'points' => 720,
				'retention' => 2592000,
				'size' => 8640,
				'offset' => 24232
			}
		],
	};


=head2 wsp_fetch ($file, $from, $until)

=head3 Parameters

	path	Simple string file path	
	from	epoch timestamp, defaults to oldest timepoint in archive
	until	epoch timestamp, defaults to now

=head3 Returns

Returns a hash refrence with data points and meta data for the given range:

	{
		'step' => 300,
		'until' => 1374830700,
		'from' => 1374830100,
		'values' => [
			'0.000000',
			'1.000000'
		],
		'cnt' => 2
	};

=head1 COPYRIGHT AND LICENSE

Original Copyright 2008 Orbitz WorldWide (python)
Perl port 2013 Jean Stebens (perl)

=cut

