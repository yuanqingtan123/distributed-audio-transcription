import unittest
from distributed_audio_transcription.controller.consolidate_srt import consolidate_srt


class TestConsolidateSrt(unittest.TestCase):
    """Test consolidate_srt function"""

    def test_first_chunk(self):
        """Test when there are no previous chunk, ie start_time=0, start_srt_seq=1"""
        # input
        start_time = 0.0
        start_srt_seq = 1
        srt_lines = [
            {
                "startTime": 0.0,
                "endTime": 1.2,
                "text": "This is the first line"
            },
            {
                "startTime": 1.2,
                "endTime": 2.3,
                "text": "This is the second line"
            },
            {
                "startTime": 2.3,
                "endTime": 3.4,
                "text": "This is the third line"
            },
        ]

        expected_output = (
            3.4,
            4,
            [
                "1\n00:00:00,000 --> 00:00:01,200\nThis is the first line\n\n",
                "2\n00:00:01,200 --> 00:00:02,300\nThis is the second line\n\n",
                "3\n00:00:02,300 --> 00:00:03,400\nThis is the third line\n\n",
            ]
        )

        test_output = consolidate_srt(start_time, start_srt_seq, srt_lines)

        self.assertTupleEqual(expected_output, test_output)

    def test_not_first_chunk(self):
        """Test when there are previous chunk, ie start_time>0, start_srt_seq>1"""
        # input
        start_time = 2.5
        start_srt_seq = 7
        srt_lines = [
            {
                "startTime": 0.0,
                "endTime": 1.2,
                "text": "This is the 7th line"
            },
            {
                "startTime": 1.2,
                "endTime": 2.3,
                "text": "This is the 8th line"
            },
            {
                "startTime": 2.3,
                "endTime": 3.4,
                "text": "This is the 9th line"
            },
        ]

        expected_output = (
            5.9,
            10,
            [
                "7\n00:00:02,500 --> 00:00:03,700\nThis is the 7th line\n\n",
                "8\n00:00:03,700 --> 00:00:04,800\nThis is the 8th line\n\n",
                "9\n00:00:04,800 --> 00:00:05,900\nThis is the 9th line\n\n",
            ]
        )

        test_output = consolidate_srt(start_time, start_srt_seq, srt_lines)

        self.assertTupleEqual(expected_output, test_output)

    def test_empty_list(self):
        """Test when srt_lines is empty list"""
        # input
        start_time = 0
        start_srt_seq = 1
        srt_lines = []

        expected_output = (
            0,
            1,
            []
        )

        test_output = consolidate_srt(start_time, start_srt_seq, srt_lines)

        self.assertTupleEqual(expected_output, test_output)


if __name__ == "__main__":
    unittest.main()
