"use client";

import { serviceMeta } from "@/lib/services";
import { GenericDetail } from "@/components/services/generic";
import {
  DetailProps,
  type ServiceCreateFieldsProps,
} from "@/components/services/shared";
import { SqsCreate, SqsDetail } from "@/components/services/sqs";
import { S3Detail } from "@/components/services/s3";

export function ServiceDetail(props: DetailProps) {
  switch (serviceMeta(props.service).id) {
    case "sqs":
      return <SqsDetail stats={props.stats} updatedAt={props.updatedAt} />;
    case "s3":
      return (
        <S3Detail
          name={props.name}
          port={props.port}
          stats={props.stats}
          updatedAt={props.updatedAt}
        />
      );
    default:
      return <GenericDetail {...props} />;
  }
}

export function ServiceCreateFields({
  service,
  ...props
}: ServiceCreateFieldsProps & { service: string }) {
  switch (serviceMeta(service).id) {
    case "sqs":
      return <SqsCreate {...props} />;
    default:
      return null;
  }
}
