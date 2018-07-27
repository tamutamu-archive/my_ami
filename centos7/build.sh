#!/bin/bash -eu


. ./var.conf


### Up working instance.
ssh_sg_id=$(aws ec2 create-security-group \
                --group-name "AMI_BUILD_SHAccess_$(date "+%Y%m%d_%H%M%S")" \
                --vpc-id "${WORK_VPC_ID}" --description "AMI_BUILD SSH access for AMI build." \
            | jq -r ".GroupId")

aws ec2 authorize-security-group-ingress --group-id "${ssh_sg_id}" --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

work_inst_id=$(aws ec2 run-instances \
   --image-id ${WORK_AMI_ID} \
   --key-name ${AWS_KEY_PAIR_NAME} \
   --security-group-ids ${ssh_sg_id} \
   --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":15,"DeleteOnTermination":true,"VolumeType":"gp2"}}]' \
   --instance-type ${WORK_EC2_TYPE} | jq -r ".Instances[].InstanceId")

aws ec2 wait instance-running --instance-id=${work_inst_id}


### Attach volume for ami.
vol_id=$(aws ec2 create-volume --size 20 --volume-type gp2 --availability-zone ${WORK_AZ} | jq -r '.VolumeId')
aws ec2 wait volume-available --volume-ids ${vol_id}
aws ec2 attach-volume --instance-id ${work_inst_id} --device ${DEVICE} --volume-id ${vol_id}


### Create rootfs for ami.
#private_ip=$(aws ec2 describe-instances --instance-id ${work_inst_id} | jq -r '.Reservations[].Instances[] | .PrivateIpAddress')
private_ip=$(aws ec2 describe-instances --instance-id ${work_inst_id} | jq -r '.Reservations[].Instances[] | .PublicIpAddress')
echo ${private_ip}

scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -r -i "${WORK_SSH_KEY_PATH}" "./" \
    "${WORK_AMI_USER}"@"${private_ip}":"/home/centos/"

ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${WORK_SSH_KEY_PATH}" "${WORK_AMI_USER}"@"${private_ip}" \
      "cd /home/centos/create_ami/ && chmod a+x ./create_ami_rootfs.sh && sudo ./create_ami_rootfs.sh"


### Create snapshot for ami.
ami_vol_id=$(aws ec2  describe-instances --instance-ids ${work_inst_id} --query "Reservations[*].Instances[*].[BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId]" | jq -r '.[] | .[] | .[] | .[]')

ami_snapshot_id=$(aws ec2 create-snapshot --volume-id ${ami_vol_id} | jq -r '.SnapshotId')

aws ec2 wait snapshot-completed --snapshot-ids ${ami_snapshot_id}

### Create my ami.
my_ami_id=$(aws ec2 register-image \
    --name 'CentOS-7.5_tamutamu' --description 'tamutamu CentOS7.5 AMI' \
    --virtualization-type hvm --root-device-name /dev/sda1 \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs": { "SnapshotId": "'${ami_snapshot_id}'", "VolumeSize":20,  "DeleteOnTermination": true, "VolumeType": "gp2"}}]' \
    --architecture x86_64 --sriov-net-support simple --ena-support | jq -r '.ImageId')

aws ec2 image-available --image-ids ${my_ami_id}


#--group-id## clean up
aws ec2 terminate-instances --instance-ids ${work_inst_id}
aws ec2 wait instance-terminated --instance-id ${work_inst_id}
aws ec2 delete-volume --volume-id ${ami_vol_id}
aws ec2 delete-security-group --group-id ${ssh_sg_id}
