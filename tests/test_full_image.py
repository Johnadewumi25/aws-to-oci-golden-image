"""Guardrails that prevent exporting the wrong or unsupported VM disk."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('full_pipeline', Path(__file__).parents[1] / 'scripts/full-image/pipeline.py')
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class ExportGuards(unittest.TestCase):
    def setUp(self):
        self.image = {'ImageId': 'ami-test', 'OwnerId': '123', 'Public': False,
                      'State': 'available', 'BootMode': 'legacy-bios',
                      'BlockDeviceMappings': [{'Ebs': {'SnapshotId': 'snap-test'}}]}
        self.manifest = {'builds': [{'artifact_id': 'us-west-1:ami-test',
                                   'custom_data': {'purpose': 'export-same-disk-to-OCI', 'version': 'test'}}]}

    def reject(self, expected, snapshots=None):
        responses = [{'Images': [self.image]}, {'Account': '123'}]
        if snapshots is not None:
            responses.append({'Snapshots': snapshots})
        with patch.object(pipeline, 'read', return_value=self.manifest), \
             patch.object(pipeline, 'aws', side_effect=responses) as api:
            with self.assertRaisesRegex(ValueError, expected):
                pipeline.start_export()
            self.assertFalse(any(call.args[:2] == ('ec2', 'export-image') for call in api.call_args_list))

    def test_foreign_image_is_rejected(self):
        self.image['OwnerId'] = 'another-account'
        self.reject('owned by this account')

    def test_public_image_is_rejected(self):
        self.image['Public'] = True
        self.reject('private AMI')

    def test_marketplace_image_is_rejected(self):
        self.image['ProductCodes'] = [{'ProductCodeId': 'licensed'}]
        self.reject('Marketplace')

    def test_multiple_disks_are_rejected(self):
        self.image['BlockDeviceMappings'].append({'Ebs': {'SnapshotId': 'snap-data'}})
        self.reject('exactly one boot disk')

    def test_encrypted_snapshot_is_rejected(self):
        self.reject('encrypted EBS', [{'Encrypted': True}])

    def test_pending_image_is_rejected(self):
        self.image['State'] = 'pending'
        self.reject('become available', [{'Encrypted': False}])

    def test_wrong_bios_alias_is_rejected(self):
        self.image['BootMode'] = 'uefi-preferred'
        self.image['Name'] = 'test'
        self.image['RootDeviceName'] = '/dev/sda1'
        wrong = dict(self.image, BootMode='legacy-bios', BlockDeviceMappings=[{'Ebs': {'SnapshotId': 'snap-WRONG'}}])
        responses = [{'Images': [self.image]}, {'Account': '123'},
                     {'Snapshots': [{'Encrypted': False}]}, {'Images': [wrong]}]
        with patch.object(pipeline, 'read', side_effect=[self.manifest, {'boot_mode': 'BIOS', 'origin': {'build_version': 'test'}}]), \
             patch.object(pipeline, 'aws', side_effect=responses):
            with self.assertRaisesRegex(ValueError, 'expected disk'):
                pipeline.start_export()


class WaitGuards(unittest.TestCase):
    def test_terminal_failure_stops_without_sleeping(self):
        with patch.object(pipeline, 'status', return_value={'Status': 'deleted', 'StatusMessage': 'unsupported image'}), \
             patch.object(pipeline.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'unsupported image'):
                pipeline.wait_export()
            sleep.assert_not_called()

    def test_timeout_preserves_running_task(self):
        with patch.object(pipeline, 'status', return_value={'Status': 'active'}), \
             patch.object(pipeline.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'task is preserved'):
                pipeline.wait_export(timeout=0)
            sleep.assert_not_called()


if __name__ == '__main__':
    unittest.main()
